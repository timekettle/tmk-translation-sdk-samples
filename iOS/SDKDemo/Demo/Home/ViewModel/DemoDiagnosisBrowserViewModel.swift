import Foundation
import Combine

/// 导航、刷新和请求代次仅由页面 ViewModel 持有；过期或取消任务不能覆盖当前目录。
final class DemoDiagnosisBrowserViewModel {
    @Published private(set) var state = DemoDiagnosisBrowserState()
    private let service: DemoDiagnosisDirectoryReading
    private var request: DemoDiagnosisBrowserRequest?
    private var generation: UInt64 = 0

    init(service: DemoDiagnosisDirectoryReading = DemoDiagnosisBrowserService()) { self.service = service }
    nonisolated deinit { request?.cancel() }

    func refresh() {
        request?.cancel()
        generation &+= 1
        let expected = generation
        state.isLoading = true
        state.message = nil
        state.entries = []
        state.totalBytes = nil
        state.savedSessionCount = nil
        request = service.load(relativePath: state.relativePath) { [weak self] result in
            guard let self, self.generation == expected else { return }
            self.state.isLoading = false
            switch result {
            case .success(let snapshot):
                if let previous = self.state.rootURL, previous != snapshot.rootURL, !self.state.relativePath.isEmpty {
                    self.state.relativePath = ""
                    self.refresh()
                    return
                }
                self.state.rootURL = snapshot.rootURL
                self.state.entries = snapshot.entries
                self.state.totalBytes = snapshot.totalBytes
                self.state.savedSessionCount = snapshot.savedSessionCount
                if snapshot.rootURL == nil { self.state.message = "尚未记录已应用的诊断根目录" }
                else if !snapshot.exists { self.state.message = "目录尚未创建或已被清理，请返回上级或刷新" }
                else if snapshot.changedDuringRead { self.state.message = "读取期间目录已变化，部分大小未知，请刷新" }
                else if snapshot.entries.isEmpty { self.state.message = "空目录" }
            case .failure(let error):
                if let changed = error as? DemoDiagnosisRootChanged {
                    self.state.rootURL = changed.rootURL
                    self.state.relativePath = ""
                    self.refresh()
                    return
                }
                if let readError = error as? DemoDiagnosisDirectoryReadError { self.state.rootURL = readError.rootURL }
                self.state.message = "读取失败：\(error.localizedDescription)"
            }
        }
    }

    func enter(_ entry: DemoDiagnosisFileEntry) {
        guard entry.kind == .directory else { return }
        state.relativePath = entry.relativePath
        refresh()
    }

    func goUp() {
        guard !state.relativePath.isEmpty else { return }
        state.relativePath = state.relativePath.split(separator: "/").dropLast().joined(separator: "/")
        refresh()
    }

    func cancel() {
        generation &+= 1
        request?.cancel()
        request = nil
        state.isLoading = false
    }
}
