import Foundation
import Darwin

/// 单个刷新任务拥有取消标记；关闭页面/新刷新不等待磁盘任务收尾。
nonisolated final class DemoDiagnosisBrowserRequest {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func checkCancellation() throws {
        lock.lock(); let value = cancelled; lock.unlock()
        if value { throw CocoaError(.userCancelled) }
    }
}

nonisolated protocol DemoDiagnosisDirectoryReading {
    @discardableResult
    func load(relativePath: String, completion: @escaping (Result<DemoDiagnosisDirectorySnapshot, Error>) -> Void) -> DemoDiagnosisBrowserRequest
}

/// 只读诊断元数据。所有遍历在后台使用相对目录 FD + O_NOFOLLOW，不解密、不读正文、不越过根目录。
nonisolated final class DemoDiagnosisBrowserService: DemoDiagnosisDirectoryReading {
    private let queue = DispatchQueue(label: "co.timekettle.demo.diagnosis.browser", qos: .utility)
    private let rootProvider: () -> URL?

    init(rootProvider: @escaping () -> URL? = { DemoDiagnosisAppliedRoot.shared.current() }) {
        self.rootProvider = rootProvider
    }

    @discardableResult
    func load(relativePath: String, completion: @escaping (Result<DemoDiagnosisDirectorySnapshot, Error>) -> Void) -> DemoDiagnosisBrowserRequest {
        let request = DemoDiagnosisBrowserRequest()
        queue.async {
            let root = self.rootProvider()
            let result = Result { try self.read(root: root, relativePath: relativePath, request: request) }
                .mapError { DemoDiagnosisDirectoryReadError(rootURL: root, underlying: $0) as Error }
            DispatchQueue.main.async {
                guard (try? request.checkCancellation()) != nil else { return }
                // 根目录来自轻量内存快照；发布前重核已应用身份，拒绝旧 root 的晚到结果。
                let currentRoot = self.rootProvider()
                guard currentRoot == root else {
                    completion(.failure(DemoDiagnosisRootChanged(rootURL: currentRoot)))
                    return
                }
                completion(result)
            }
        }
        return request
    }

    private func read(root: URL?, relativePath: String, request: DemoDiagnosisBrowserRequest) throws -> DemoDiagnosisDirectorySnapshot {
        try request.checkCancellation()
        guard let root else {
            return .init(rootURL: nil, relativePath: "", exists: false, entries: [])
        }
        let parts = relativePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard relativePath.isEmpty || (!relativePath.hasPrefix("/") && parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\0") })) else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EINVAL))
        }
        let rootFD = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if rootFD < 0 {
            if errno == ENOENT { return .init(rootURL: root, relativePath: relativePath, exists: false, entries: []) }
            throw posixError()
        }
        defer { close(rootFD) }
        // dup共享readdir偏移；页面读取与根目录汇总各自重新打开目录，避免第二次扫描为空。
        var fd = openat(rootFD, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw posixError() }
        defer { close(fd) }
        for component in relativePath.isEmpty ? [] : parts {
            try request.checkCancellation()
            let next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if next < 0 {
                if errno == ENOENT { return .init(rootURL: root, relativePath: relativePath, exists: false, entries: []) }
                throw posixError()
            }
            close(fd); fd = next
        }
        var entries: [DemoDiagnosisFileEntry] = []
        var changed = false
        for name in try names(in: fd, request: request) {
            // 只隐藏已知内部清单；其他隐藏/未知文件仍供 QA 观察。大小统计保持完整。
            if [".session_manifest.json", "session_manifest.json", ".sdk_manifest.json", "sdk_context.json"].contains(name) { continue }
            try request.checkCancellation()
            guard let info = try metadata(at: fd, name: name) else { changed = true; continue }
            let kind = kind(of: info)
            var bytes: Int64? = max(0, Int64(info.st_size))
            if kind == .directory {
                let child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                if child < 0 {
                    if errno == ENOENT { changed = true; continue }
                    throw posixError()
                }
                defer { close(child) }
                bytes = try directorySize(child, request: request, depth: 0)
                if bytes == nil { changed = true }
            }
            entries.append(.init(name: name, relativePath: relativePath.isEmpty ? name : "\(relativePath)/\(name)",
                                 kind: kind, sizeBytes: bytes,
                                 modifiedAt: Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9)))
        }
        entries.sort {
            let lhs = $0.modifiedAt ?? .distantPast
            let rhs = $1.modifiedAt ?? .distantPast
            if lhs != rhs { return lhs > rhs }
            return $0.name < $1.name
        }
        let summaryFD = openat(rootFD, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        var summary: (bytes: Int64, sessions: Int)?
        if summaryFD >= 0 {
            defer { close(summaryFD) }
            do { summary = try rootUsage(summaryFD, request: request) }
            catch { try request.checkCancellation(); summary = nil }
        }
        try request.checkCancellation()
        return .init(rootURL: root, relativePath: relativePath, exists: true, entries: entries,
                     changedDuringRead: changed, totalBytes: summary?.bytes, savedSessionCount: summary?.sessions)
    }

    private struct FileIdentity: Hashable {
        let device: dev_t
        let inode: ino_t
    }

    /// 全root普通文件使用设备号+inode去重；只在root一级判断会话目录。
    private func rootUsage(_ rootFD: Int32, request: DemoDiagnosisBrowserRequest) throws -> (bytes: Int64, sessions: Int)? {
        var total: Int64 = 0
        var sessions = 0
        var identities = Set<FileIdentity>()
        func visit(_ directoryFD: Int32, depth: Int) throws -> Bool {
            guard depth < 128 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(ELOOP)) }
            for name in try names(in: directoryFD, request: request) {
                try request.checkCancellation()
                guard let info = try metadata(at: directoryFD, name: name) else { return false }
                switch kind(of: info) {
                case .directory:
                    let child = openat(directoryFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    if child < 0 { if errno == ENOENT { return false }; throw posixError() }
                    defer { close(child) }
                    if depth == 0, try isSavedConversation(child, name: name) { sessions += 1 }
                    guard try visit(child, depth: depth + 1) else { return false }
                case .file:
                    guard identities.insert(FileIdentity(device: info.st_dev, inode: info.st_ino)).inserted else { continue }
                    let sum = total.addingReportingOverflow(max(0, Int64(info.st_size)))
                    total = sum.overflow ? Int64.max : sum.partialValue
                case .symbolicLink, .other: break
                }
            }
            return true
        }
        guard try visit(rootFD, depth: 0) else { return nil }
        return (total, sessions)
    }

    private func isSavedConversation(_ directoryFD: Int32, name: String) throws -> Bool {
        if name == "Agora" || name == "sdk_contexts" { return false }
        for manifest in [".session_manifest.json", "session_manifest.json"] {
            if let info = try metadata(at: directoryFD, name: manifest), kind(of: info) == .file { return true }
        }
        let pattern = #"^[A-Za-z0-9][A-Za-z0-9_-]*_(?:online|offline)_([0-9]{8}_[0-9]{6})(?:_(?:[0-9a-f]{4}|[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}))?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: name, range: NSRange(name.startIndex..<name.endIndex, in: name)),
              match.range == NSRange(name.startIndex..<name.endIndex, in: name),
              let range = Range(match.range(at: 1), in: name) else { return false }
        let stamp = String(name[range])
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        formatter.isLenient = false
        return formatter.date(from: stamp).map { formatter.string(from: $0) == stamp } ?? false
    }

    private func directorySize(_ fd: Int32, request: DemoDiagnosisBrowserRequest, depth: Int) throws -> Int64? {
        guard depth < 128 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(ELOOP)) }
        var size: Int64 = 0
        var changed = false
        for name in try names(in: fd, request: request) {
            try request.checkCancellation()
            guard let info = try metadata(at: fd, name: name) else { changed = true; continue }
            let bytes: Int64?
            if kind(of: info) == .directory {
                let child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                if child < 0 { if errno == ENOENT { changed = true; continue }; throw posixError() }
                defer { close(child) }
                bytes = try directorySize(child, request: request, depth: depth + 1)
            } else if kind(of: info) == .file {
                bytes = max(0, Int64(info.st_size))
            } else {
                // 目录大小只统计后代普通文件；符号链接仅显示自身元数据，永不计入目标内容。
                bytes = 0
            }
            guard let bytes else { changed = true; continue }
            let sum = size.addingReportingOverflow(bytes)
            size = sum.overflow ? Int64.max : sum.partialValue
        }
        return changed ? nil : size
    }

    private func names(in fd: Int32, request: DemoDiagnosisBrowserRequest) throws -> [String] {
        let duplicate = dup(fd)
        guard duplicate >= 0 else { throw posixError() }
        guard let directory = fdopendir(duplicate) else { let error = posixError(); close(duplicate); throw error }
        defer { closedir(directory) }
        var result: [String] = []
        while true {
            try request.checkCancellation()
            errno = 0
            guard let entry = readdir(directory) else {
                if errno != 0 { throw posixError() }
                break
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if name != "." && name != ".." { result.append(name) }
        }
        return result
    }

    private func metadata(at fd: Int32, name: String) throws -> stat? {
        var info = stat()
        guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { return nil }
            throw posixError()
        }
        return info
    }

    private func kind(of info: stat) -> DemoDiagnosisFileEntry.Kind {
        switch info.st_mode & S_IFMT {
        case S_IFDIR: return .directory
        case S_IFREG: return .file
        case S_IFLNK: return .symbolicLink
        default: return .other
        }
    }
    private func posixError() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
}
