import Foundation

nonisolated struct DemoDiagnosisFileEntry: Equatable {
    enum Kind: String { case directory = "目录", file = "文件", symbolicLink = "符号链接", other = "其他" }
    let name: String
    let relativePath: String
    let kind: Kind
    let sizeBytes: Int64?
    let modifiedAt: Date

    var formattedSize: String {
        guard let sizeBytes else { return "大小未知" }
        return Self.formatBytes(sizeBytes)
    }

    static func formatBytes(_ sizeBytes: Int64) -> String {
        guard sizeBytes >= 1024 else { return "\(sizeBytes) B" }
        let units = ["KiB", "MiB", "GiB", "TiB", "PiB", "EiB"]
        var amount = Double(sizeBytes) / 1024
        var index = 0
        while amount >= 1024 && index < units.count - 1 { amount /= 1024; index += 1 }
        return String(format: "%.1f %@ (%lld B)", amount, units[index], sizeBytes)
    }
}

nonisolated struct DemoDiagnosisDirectorySnapshot: Equatable {
    let rootURL: URL?
    let relativePath: String
    let exists: Bool
    let entries: [DemoDiagnosisFileEntry]
    var changedDuringRead = false
    var totalBytes: Int64? = nil
    var savedSessionCount: Int? = nil
}

/// 主线程持有页面状态；文件系统服务不持有视图或导航状态。
nonisolated struct DemoDiagnosisBrowserState {
    var rootURL: URL?
    var relativePath = ""
    var entries: [DemoDiagnosisFileEntry] = []
    var isLoading = false
    var totalBytes: Int64? = nil
    var savedSessionCount: Int? = nil
    var message: String?
}

nonisolated struct DemoDiagnosisRootChanged: Error { let rootURL: URL? }
nonisolated struct DemoDiagnosisDirectoryReadError: LocalizedError {
    let rootURL: URL?
    let underlying: Error
    var errorDescription: String? { underlying.localizedDescription }
}
