import Foundation

/// 仅在真实 sdkInit 返回后记录；浏览保留最后一次已应用根目录，不读取设置草稿或触发 SDK flush。
nonisolated final class DemoDiagnosisAppliedRoot {
    static let shared = DemoDiagnosisAppliedRoot()
    private let lock = NSLock()
    private var root: URL?

    func record(_ root: URL?) {
        lock.lock()
        self.root = root
        lock.unlock()
    }

    func current() -> URL? {
        lock.lock()
        defer { lock.unlock() }
        return root
    }
}
