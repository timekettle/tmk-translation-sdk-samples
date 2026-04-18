//
//  OfflineListenViewModel.swift
//  TmkTranslationSDKDemo
//
//  Created by Kiro on 2026/1/28.
//

import Foundation
import Combine
import AVFAudio
import CoreAudioTypes
import TmkTranslationSDK

typealias OfflineLanguageOption = (code: String, name: String)

/// 离线现场收听 ViewModel。
/// 复用 NowListeningViewState / NowListeningRowViewData，去除在线房间相关流程，
/// 使用 createOfflineTranslationChannel 创建通道，语言列表使用 SDK 提供的离线支持列表。
final class OfflineListenViewModel: NSObject {
    @Published private(set) var state = NowListeningViewState()
    let rowMutation = PassthroughSubject<ChatListMutation<NowListeningRowViewData>, Never>()
    @Published private(set) var downloadButtonState: OfflineModelButtonState = .notDownloaded
    @Published private(set) var downloadStatusText: String = ""
    @Published private(set) var showCancelButton: Bool = false
    @Published private(set) var modelPackageInfos: [TmkOfflineModelPackageInfo] = []
    @Published private(set) var supportedLanguages: [OfflineLanguageOption] = []

    private var channel: TmkTranslationChannel?
    private var voiceIO: TmkVoiceProcessingIO?
    private var hasStoppedListening = false

    private var rows: [NowListeningRowViewData] = []
    private var bubbleIndexMap: [String: Int] = [:]
    private let bubbleAssembler = DemoConversationBubbleAssembler()
    private var pendingRowsPublishWorkItem: DispatchWorkItem?
    private var lastPublishedRows: [NowListeningRowViewData] = []
    private var selectedSourceLang = "zh"
    private var selectedTargetLang = "en"
    private let maxDisplayedRows = 200
    private var downloadStatusHeader = ""

    private let stateLock = NSLock()
    private var isListeningActive = false
    private var lastPlaybackChannels = 0
    private var offlineSupportChecked = false
    private var offlineTranslationSupported = false
    private let lingCastAspect = DemoLingCastAspect()

    /// 模型根目录（App Documents/tmkOfflineModel/）。
    private var modelRootDirectory: String {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("tmkOfflineModel").path
    }

    func configureInitialLanguages(source: String?, target: String?) {
        if let source, source.isEmpty == false {
            selectedSourceLang = source
        }
        if let target, target.isEmpty == false {
            selectedTargetLang = target
        }
    }

    func onViewDidLoad() {
        lingCastAspect.updateModeName("listen")
        lingCastAspect.updateTransEngineName("offline")
        lingCastAspect.setTraceReportingEnabled(true)
        loadOfflineSupportedLanguages()
        updateStateOnMain {
            $0.sourceLanguage = self.selectedSourceLang
            $0.targetLanguage = self.selectedTargetLang
            $0.currentMode = "offline"
            $0.currentScenario = "listen"
        }
        verifyAuthThenRefreshOfflineState(autoStartIfReady: true)
    }

    func onViewWillClose() {
        TmkTranslationSDK.shared.cancelOfflineModelDownload()
        lingCastAspect.onConversationEnd()
        stopListeningIfNeeded()
    }

    /// 检查模型就绪状态并更新按钮。
    func checkModelReadyAndUpdateButton(autoStartIfReady: Bool = true,
                                        autoDownloadIfNeeded: Bool = false) {
        guard offlineTranslationSupported else {
            applyOfflineUnsupportedState()
            return
        }
        let packageInfos = TmkTranslationSDK.shared.getOfflineModelPackageInfos(
            srcLang: selectedSourceLang,
            dstLang: selectedTargetLang,
            modelRootDirectory: modelRootDirectory,
            scenario: .listen
        )
        let ready = TmkTranslationSDK.shared.isOfflineModelReady(
            srcLang: selectedSourceLang,
            dstLang: selectedTargetLang,
            modelRootDirectory: modelRootDirectory,
            scenario: .listen
        )
        DispatchQueue.main.async {
            self.modelPackageInfos = packageInfos
            self.updateDownloadPackageListStatusText()
            if ready {
                self.downloadButtonState = .ready
                self.updateDownloadPackageListStatusText(header: "模型已就绪")
                if autoStartIfReady {
                    self.createOfflineChannel()
                }
            } else {
                self.stopCurrentChannelForMissingModels()
                self.downloadButtonState = .notDownloaded
                self.updateDownloadPackageListStatusText(
                    header: "当前模型资源不完整，需要先下载"
                )
                self.updateStatus("当前模型资源不完整，需要先下载离线资源")
                self.updateStateOnMain {
                    $0.canStartListening = false
                    $0.canStopListening = false
                }
                if autoDownloadIfNeeded {
                    self.startModelDownloadIfSupported()
                }
            }
        }
    }

    /// 触发模型下载。
    func downloadModel() {
        if offlineSupportChecked == false {
            verifyAuthThenRefreshOfflineState(autoStartIfReady: false, autoDownloadIfNeeded: true)
            return
        }
        guard offlineTranslationSupported else {
            applyOfflineUnsupportedState()
            return
        }
        startModelDownloadIfSupported()
    }

    /// 取消模型下载。
    func cancelDownload() {
        TmkTranslationSDK.shared.cancelOfflineModelDownload()
        downloadButtonState = .notDownloaded
        downloadStatusText = "下载已取消"
        showCancelButton = false
    }

    func startListening() {
        guard offlineTranslationSupported else {
            applyOfflineUnsupportedState()
            return
        }
        guard TmkTranslationSDK.shared.isOfflineModelReady(
            srcLang: selectedSourceLang,
            dstLang: selectedTargetLang,
            modelRootDirectory: modelRootDirectory,
            scenario: .listen
        ) else {
            updateStatus("当前模型资源不完整，需要先下载离线资源")
            checkModelReadyAndUpdateButton(autoStartIfReady: false)
            return
        }
        guard state.canStartListening, let channel else {
            updateStatus("离线通道尚未就绪，请等待模型校验和初始化完成")
            return
        }
        if voiceIO == nil {
            voiceIO = TmkVoiceProcessingIO(config: TmkVPConfig(sampleRate: 16_000,
                                                               channels: 1,
                                                               bitsPerChannel: 16,
                                                               framesPerBuffer: 512))
        }
        guard let voiceIO else { return }
        do {
            try TmkVoiceProcessingIO.configureAudioSession(sampleRate: 16000,
                                                           framesPerBuffer: 512,
                                                           mode: .voiceChat,
                                                           useSpeaker: true)
        } catch {
            updateStatus("音频会话配置失败：\(error.localizedDescription)")
            return
        }
        voiceIO.onInputPCM = { [weak self, weak channel] data, format in
            guard let self else { return }
            let captureChannels = Int(format.mChannelsPerFrame)
            self.updateCaptureAudioInfo(sampleRate: Int(format.mSampleRate), channels: captureChannels)
            channel?.pushStreamAudioData(data, channelCount: captureChannels, extraChunk: nil)
        }
        voiceIO.requestRecordPermission { [weak self] granted in
            guard let self else { return }
            guard granted else {
                self.updateStatus("麦克风权限未授权")
                return
            }
            do {
                try voiceIO.start()
                self.setListeningActive(true)
                self.updateStateOnMain {
                    $0.canStopListening = true
                    $0.canStartListening = false
                }
                self.updateStatus("离线收听中...")
            } catch {
                self.updateStatus("开始收听失败：\(error.localizedDescription)")
            }
        }
    }

    func stopListening() {
        voiceIO?.stop()
        setListeningActive(false)
        updateStateOnMain {
            $0.canStopListening = false
            $0.canStartListening = self.channel != nil
            $0.playbackChannels = 0
        }
        lastPlaybackChannels = 0
        updateStatus("收听已停止")
    }

    func applyLanguages(source: String, target: String) {
        guard source != target else {
            updateStatus("源语言和目标语言不能相同")
            return
        }
        selectedSourceLang = source
        selectedTargetLang = target
        updateStateOnMain {
            $0.sourceLanguage = source
            $0.targetLanguage = target
            $0.rows = []
        }
        resetRows()
        voiceIO?.stop()
        setListeningActive(false)
        lingCastAspect.onConversationEnd()
        TmkTranslationSDK.shared.releaseChannel()
        channel = nil
        hasStoppedListening = false
        updateStateOnMain {
            $0.canStartListening = false
            $0.canStopListening = false
        }
        offlineSupportChecked = false
        offlineTranslationSupported = false
        updateStatus("语言已切换，正在重新鉴权并检测离线能力...")
        verifyAuthThenRefreshOfflineState(autoStartIfReady: true)
    }
}

private extension OfflineListenViewModel {
    static func makeLanguageOptions(from response: TmkSupportedLanguagesResponse) -> [OfflineLanguageOption] {
        response.localeOptions.map {
            let title = $0.uiLang.isEmpty ? $0.nativeLang : $0.uiLang
            return (code: $0.code, name: title)
        }
    }

    func resetRows() {
        rows.removeAll()
        bubbleIndexMap.removeAll()
        bubbleAssembler.reset()
        lastPublishedRows = []
        pendingRowsPublishWorkItem?.cancel()
        pendingRowsPublishWorkItem = nil
        rowMutation.send(.reset(rows: []))
    }

    func loadOfflineSupportedLanguages() {
        _ = TmkTranslationSDK.shared.getSupportedLanguages(source: .offline) { [weak self] result in
            guard let self else { return }
            guard case .success(let response) = result else { return }
            let options = Self.makeLanguageOptions(from: response)
            guard options.isEmpty == false else { return }
            self.supportedLanguages = options
            if options.contains(where: { $0.code == self.selectedSourceLang }) == false {
                self.selectedSourceLang = options.first?.code ?? self.selectedSourceLang
            }
            if options.contains(where: { $0.code == self.selectedTargetLang }) == false {
                self.selectedTargetLang = options.first(where: { $0.code != self.selectedSourceLang })?.code
                    ?? options.first?.code
                    ?? self.selectedTargetLang
            }
            self.updateStateOnMain {
                $0.sourceLanguage = self.selectedSourceLang
                $0.targetLanguage = self.selectedTargetLang
            }
        }
    }

    func verifyAuthThenRefreshOfflineState(autoStartIfReady: Bool,
                                           autoDownloadIfNeeded: Bool = false) {
        downloadButtonState = .checking
        showCancelButton = false
        updateDownloadPackageListStatusText(header: "正在鉴权并检查离线能力...")
        updateStatus("正在鉴权...")
        TmkTranslationSDK.shared.verifyAuth { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.offlineSupportChecked = true
                self.offlineTranslationSupported = TmkTranslationSDK.shared.isOfflineTranslationSupported()
                guard self.offlineTranslationSupported else {
                    self.applyOfflineUnsupportedState()
                    return
                }
                self.checkModelReadyAndUpdateButton(autoStartIfReady: autoStartIfReady,
                                                    autoDownloadIfNeeded: autoDownloadIfNeeded)
            case .failure(let error):
                self.offlineSupportChecked = false
                self.offlineTranslationSupported = false
                self.downloadButtonState = .notDownloaded
                self.showCancelButton = false
                self.updateDownloadPackageListStatusText(header: "鉴权失败，无法使用离线翻译")
                self.updateStatus("鉴权失败：\(error.message)")
                self.stopCurrentChannelForMissingModels()
                self.updateStateOnMain {
                    $0.canStartListening = false
                    $0.canStopListening = false
                }
            }
        }
    }

    func applyOfflineUnsupportedState() {
        stopCurrentChannelForMissingModels()
        downloadButtonState = .unsupported
        showCancelButton = false
        updateDownloadPackageListStatusText(header: "当前账号不支持离线翻译")
        updateStatus("当前账号未开通离线翻译能力")
        updateStateOnMain {
            $0.canStartListening = false
            $0.canStopListening = false
        }
    }

    func startModelDownloadIfSupported() {
        guard offlineTranslationSupported else {
            applyOfflineUnsupportedState()
            return
        }
        downloadButtonState = .downloading
        downloadStatusText = "准备下载..."
        showCancelButton = true
        TmkTranslationSDK.shared.downloadOfflineModels(
            srcLang: selectedSourceLang,
            dstLang: selectedTargetLang,
            modelRootDirectory: modelRootDirectory,
            scenario: .listen,
            listener: self
        )
    }

    func createOfflineChannel() {
        guard offlineTranslationSupported else {
            applyOfflineUnsupportedState()
            return
        }
        guard TmkTranslationSDK.shared.isOfflineModelReady(
            srcLang: selectedSourceLang,
            dstLang: selectedTargetLang,
            modelRootDirectory: modelRootDirectory,
            scenario: .listen
        ) else {
            downloadButtonState = .notDownloaded
            checkModelReadyAndUpdateButton(autoStartIfReady: false, autoDownloadIfNeeded: false)
            updateStatus("当前模型资源不完整，需要先下载离线资源")
            return
        }
        DispatchQueue.main.async {
            self.downloadButtonState = .checking
            self.updateDownloadPackageListStatusText(header: "模型校验中...")
            self.showCancelButton = false
        }
        let config = TmkTranslationChannelConfig.Builder()
            .setMode(.offline)
            .setScenario(.listen)
            .setSourceLang(selectedSourceLang)
            .setTargetLang(selectedTargetLang)
            .setPCMSampleRate(16_000)
            .setPCMChannels(1)
            .setModelRootDirectory(modelRootDirectory)
            .build()
        updateStateOnMain {
            $0.configuredSampleRate = config.pcmSampleRate
            $0.configuredChannels = config.pcmChannels
        }
        lingCastAspect.updateLanguages(source: selectedSourceLang, target: selectedTargetLang)
        lingCastAspect.onJoinRoomStarted()
        updateStatus("正在加载离线模型...")
        TmkTranslationSDK.shared.createTranslationChannel(config, listener: self) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let channel):
                self.lingCastAspect.onJoinRoomFinished(error: nil)
                self.channel = channel
                self.updateStateOnMain { $0.canStartListening = true }
                self.downloadButtonState = .ready
                self.updateDownloadPackageListStatusText(header: "模型已就绪")
                self.updateStatus(#"离线通道已就绪，点击"开始收听"开始采集"#)
            case .failure(let error):
                self.lingCastAspect.onJoinRoomFinished(error: error)
                self.downloadButtonState = .notDownloaded
                self.checkModelReadyAndUpdateButton(autoStartIfReady: false, autoDownloadIfNeeded: false)
                self.updateStatus("离线通道创建失败：\(error.localizedDescription)")
            }
        }
    }

    func stopListeningIfNeeded() {
        guard hasStoppedListening == false else { return }
        hasStoppedListening = true
        pendingRowsPublishWorkItem?.cancel()
        pendingRowsPublishWorkItem = nil
        setListeningActive(false)
        lingCastAspect.onConversationEnd()
        voiceIO?.stop()
        voiceIO = nil
        TmkTranslationSDK.shared.releaseChannel()
        channel = nil
        updateStatus("已停止收听")
    }

    func stopCurrentChannelForMissingModels() {
        voiceIO?.stop()
        setListeningActive(false)
        lingCastAspect.onConversationEnd()
        TmkTranslationSDK.shared.releaseChannel()
        channel = nil
    }

    func updateStatus(_ text: String) {
        updateStateOnMain { $0.statusText = text }
    }

    func updateCaptureAudioInfo(sampleRate: Int, channels: Int) {
        updateStateOnMain {
            $0.captureSampleRate = sampleRate
            $0.captureChannels = channels
        }
    }

    func updateStateOnMain(_ action: @escaping (inout NowListeningViewState) -> Void) {
        DispatchQueue.main.async {
            var newState = self.state
            action(&newState)
            self.state = newState
        }
    }

    func updateDownloadPackageListStatusText(header: String? = nil) {
        if let header {
            downloadStatusHeader = header
        }
        let lines = modelPackageInfos.map { Self.formatPackageLine($0) }
        if downloadStatusHeader.isEmpty == false {
            downloadStatusText = ([downloadStatusHeader] + lines).joined(separator: "\n")
        } else {
            downloadStatusText = lines.joined(separator: "\n")
        }
    }

    func setListeningActive(_ active: Bool) {
        stateLock.lock()
        isListeningActive = active
        stateLock.unlock()
    }

    func getListeningActive() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return isListeningActive
    }

    func applyBubbleSnapshot(_ snapshot: DemoConversationBubbleSnapshot) {
        DispatchQueue.main.async {
            let key = DemoConversationBubbleAssembler.rowKey(bubbleId: snapshot.bubbleId, lane: .left)
            if let rowIndex = self.bubbleIndexMap[key], self.rows.indices.contains(rowIndex) {
                var row = self.rows[rowIndex]
                row.sessionId = snapshot.sessionId
                row.sourceLangCode = snapshot.sourceLangCode
                row.targetLangCode = snapshot.targetLangCode
                row.sourceText = snapshot.sourceText
                row.translatedText = snapshot.translatedText
                self.rows[rowIndex] = row
                self.rowMutation.send(.update(row: row, index: rowIndex, heightMayChange: true))
                self.publishRows()
                return
            }
            let row = NowListeningRowViewData(sessionId: snapshot.sessionId,
                                              bubbleId: snapshot.bubbleId,
                                              sourceLangCode: snapshot.sourceLangCode,
                                              targetLangCode: snapshot.targetLangCode,
                                              sourceText: snapshot.sourceText,
                                              translatedText: snapshot.translatedText)
            self.rows.append(row)
            let newIndex = self.rows.count - 1
            self.bubbleIndexMap[key] = newIndex
            self.rowMutation.send(.insert(row: row, index: newIndex))
            self.trimRowsIfNeeded()
            self.publishRows()
        }
    }

    func trimRowsIfNeeded() {
        guard rows.count > maxDisplayedRows else { return }
        let overflow = rows.count - maxDisplayedRows
        for _ in 0..<overflow {
            rows.removeFirst()
            rowMutation.send(.delete(index: 0))
        }
        var newIndexMap: [String: Int] = [:]
        for (index, row) in rows.enumerated() {
            let key = DemoConversationBubbleAssembler.rowKey(bubbleId: row.bubbleId, lane: .left)
            newIndexMap[key] = index
        }
        bubbleIndexMap = newIndexMap
    }

    func publishRows() {
        pendingRowsPublishWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.lastPublishedRows != self.rows else { return }
            self.lastPublishedRows = self.rows
            self.updateStateOnMain { $0.rows = self.rows }
        }
        pendingRowsPublishWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: workItem)
    }

}

extension OfflineListenViewModel: TmkTranslationListener, TmkOfflineModelDownloadListener {
    func onRecognized(from engine: AbstractChannelEngine, result: TmkResult<String>, isFinal: Bool) {
        _ = engine
        guard let event = DemoConversationEventAdapter.makeRecognizedEvent(from: result, isFinal: isFinal) else { return }
        let normalized = DemoConversationEvent(bubbleId: event.bubbleId,
                                               sessionId: event.sessionId,
                                               lane: .left,
                                               stage: event.stage,
                                               isFinal: event.isFinal,
                                               text: event.text,
                                               sourceLangCode: event.sourceLangCode,
                                               targetLangCode: event.targetLangCode)
        guard let snapshot = bubbleAssembler.consume(normalized) else { return }
        applyBubbleSnapshot(snapshot)
    }

    func onTranslate(from engine: AbstractChannelEngine, result: TmkResult<String>, isFinal: Bool) {
        _ = engine
        guard let event = DemoConversationEventAdapter.makeTranslatedEvent(from: result, isFinal: isFinal) else { return }
        let normalized = DemoConversationEvent(bubbleId: event.bubbleId,
                                               sessionId: event.sessionId,
                                               lane: .left,
                                               stage: event.stage,
                                               isFinal: event.isFinal,
                                               text: event.text,
                                               sourceLangCode: event.sourceLangCode,
                                               targetLangCode: event.targetLangCode)
        guard let snapshot = bubbleAssembler.consume(normalized) else { return }
        applyBubbleSnapshot(snapshot)
    }

    func onAudioDataReceive(from engine: AbstractChannelEngine, result: TmkResult<String>, data: Data, channelCount: Int) {
        guard result.data == "translated_audio" else { return }
        guard getListeningActive() else { return }
        if lastPlaybackChannels != channelCount {
            lastPlaybackChannels = channelCount
            updateStateOnMain { $0.playbackChannels = channelCount }
        }
        voiceIO?.enqueuePlaybackPCM(data)
    }

    func onError(_ error: TmkTranslationError) {
        let message = "错误[\(error.category.rawValue)] \(error.message)"
        updateStatus(message)
        lingCastAspect.onSDKError(error)
        DispatchQueue.main.async {
            if self.downloadButtonState == .downloading {
                self.downloadButtonState = .notDownloaded
                self.updateDownloadPackageListStatusText(header: "下载出错：\(error.message)")
                self.showCancelButton = false
            }
        }
    }

    func onEvent(name: String, args: Any?) {
        lingCastAspect.onEvent(name: name, args: args)
    }

    func onOfflineModelEvent(name: String, args: Any?) {
        _ = args
        if name == "offline_model_cancelled" {
            DispatchQueue.main.async {
                self.downloadButtonState = .notDownloaded
                self.updateDownloadPackageListStatusText(header: "下载已取消")
                self.showCancelButton = false
            }
        } else if name == "offline_model_update_required" {
            DispatchQueue.main.async {
                self.downloadButtonState = .updateRequired
                self.updateDownloadPackageListStatusText(header: "模型资源有更新，请重新下载")
                self.showCancelButton = false
                self.updateStateOnMain { $0.canStartListening = false }
            }
        }
    }

    func onOfflineModelError(_ error: TmkTranslationError) {
        onError(error)
    }

    func onOfflineModelDownloadProgress(fileName: String, index: Int, total: Int, downloaded: Int64, fileTotal: Int64) {
        DispatchQueue.main.async {
            self.downloadButtonState = .downloading
            if downloaded == -1 {
                self.updateDownloadPackageListStatusText(header: "当前文件：\(fileName)\n正在下载（\(index)/\(total)）")
            } else {
                let dlStr = Self.formatBytes(downloaded)
                let totalStr = fileTotal > 0 ? Self.formatBytes(fileTotal) : "未知"
                let percentText = Self.formatPercent(downloaded: downloaded, total: fileTotal)
                self.updateDownloadPackageListStatusText(
                    header: "当前文件：\(fileName)\n下载进度：\(percentText)（\(index)/\(total)）\n\(dlStr) / \(totalStr)"
                )
            }
        }
    }

    func onOfflineModelUnzipProgress(fileName: String, progress: Double) {
        DispatchQueue.main.async {
            let pct = Int(progress * 100)
            self.updateDownloadPackageListStatusText(header: "解压 \(fileName) \(pct)%")
        }
    }

    func onOfflineModelReady() {
        DispatchQueue.main.async {
            self.downloadButtonState = .ready
            self.showCancelButton = false
            self.updateDownloadPackageListStatusText(header: "下载完成，正在校验模型完整性...")
            self.checkModelReadyAndUpdateButton(autoStartIfReady: true)
        }
    }

    func onOfflineModelPackageInfosChanged(_ packages: [TmkOfflineModelPackageInfo]) {
        DispatchQueue.main.async {
            self.modelPackageInfos = packages
            self.updateDownloadPackageListStatusText()
        }
    }

    private func setDownloadStatus(_ text: String) {
        downloadStatusText = text
        updateStatus(text)
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        let mb = Double(bytes) / (1024.0 * 1024.0)
        return String(format: "%.1f MB", mb)
    }

    private static func formatPercent(downloaded: Int64, total: Int64) -> String {
        guard total > 0 else { return "--" }
        let percent = min(max(Double(downloaded) / Double(total), 0), 1)
        return String(format: "%.0f%%", percent * 100.0)
    }

    private static func formatPackageLine(_ package: TmkOfflineModelPackageInfo) -> String {
        let stateText: String
        switch package.state {
        case .ready:
            stateText = "已就绪"
        case .needsDownload:
            stateText = "待下载"
        case .needsUpdate:
            stateText = "需更新"
        case .resumable:
            stateText = "可续传"
        case .downloading:
            let percent = formatPercent(downloaded: package.downloadedBytes, total: package.totalBytes)
            let downloaded = formatBytes(package.downloadedBytes)
            let total = package.totalBytes > 0 ? formatBytes(package.totalBytes) : "未知"
            stateText = "下载中 \(percent) \(downloaded)/\(total)"
        case .unzipping:
            let percent = Int(min(max(package.unzipProgress, 0), 1) * 100)
            stateText = "解压中 \(percent)%"
        case .failed:
            stateText = "失败"
        case .cancelled:
            stateText = "已取消"
        }
        return "• \(package.packageKey) [\(stateText)]"
    }
}
