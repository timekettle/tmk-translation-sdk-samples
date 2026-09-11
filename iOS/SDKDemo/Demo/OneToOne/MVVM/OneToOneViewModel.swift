import Foundation
import Combine
import OSLog
import TmkTranslationSDK
import AVFoundation

final class OneToOneViewModel: NSObject {
    private static let logger = Logger(subsystem: "co.timekettle.demo", category: "OneToOne")
    private static let maxPendingPlaybackAudioBytes = 512 * 1024
    private static let rowUpdateInterval: TimeInterval = 0.12

    @Published private(set) var state = OneToOneViewState()
    let rowMutation = PassthroughSubject<ChatListMutation<OneToOneRowViewData>, Never>()
    let remoteCloseRoomPrompt = PassthroughSubject<DemoConversationPrompt, Never>()
    let dismissReconnectTimeoutPrompt = PassthroughSubject<Void, Never>()

    private var room: TmkTranslationRoom?
    private var channel: TmkTranslationChannel?
    private var voiceIO: TmkVoiceProcessingIO?
    private var hasStoppedListening = false
    private lazy var ttsCoordinator = DemoTtsPlaybackCoordinator(
        scene: .oneToOne,
        processQueue: audioProcessQueue,
        backpressure: audioFrameBackpressure,
        sourceLaneResolver: { [weak self] result, audioRoute in
            guard let self else { return nil }
            // 对齐原实现：无 audio_route 时按 uid→lane 映射兜底；有路由时走 sourceLane 默认逻辑。
            guard audioRoute == nil else { return nil }
            return self.audioUID(from: result).flatMap { self.playbackLaneByUID[$0] }
        },
        onPlaybackChannelsChanged: { [weak self] channels in
            self?.updatePlaybackChannel(channels)
        }
    )
    private var rows: [OneToOneRowViewData] = []
    private var rowIndexMap: [String: Int] = [:]
    private var bubbleLaneMap: [String: OneToOneRowViewData.Lane] = [:]
    /// raw sessionId → 所在行 rowKey（源文按 session 命中）。
    private var rawSessionRowKey: [Int: String] = [:]
    /// raw chunkId → 所在行 rowKey（译文按 chunk 命中）。
    private var rawChunkRowKey: [String: String] = [:]
    /// 当前应高亮的 session_id（源文蓝色），由 online_tts_state.is_end 控制。
    private var blueSessions: Set<Int> = []
    /// 当前应高亮的 chunk_id（译文蓝色），由 online_tts_state.is_end 控制。
    private var blueChunks: Set<String> = []
    private let bubbleAssembler = DemoConversationBubbleAssembler(maxRows: 20)
    private var pendingRowsPublishWorkItem: DispatchWorkItem?
    private var lastPublishedRows: [OneToOneRowViewData] = []
    private lazy var rowUpdateCoalescer = DemoLatestKeyUpdateCoalescer<String>(
        interval: Self.rowUpdateInterval,
        scheduler: { interval, action in
            DispatchQueue.main.asyncAfter(deadline: .now() + interval, execute: action)
        },
        onFlush: { [weak self] keys in
            self?.publishLatestRows(for: keys)
        }
    )

    private var targetPlaybackUIDs: Set<Int> = []
    private var activePlaybackUID: Int?
    private var playbackLaneByUID: [Int: OneToOneRowViewData.Lane] = [:]
    private var selectedSourceLang = "zh-CN"
    private var selectedTargetLang = "en-US"
    private var selectedRightLang: String { selectedSourceLang }
    private var selectedLeftLang: String { selectedTargetLang }
    private var selectedLeftSpeakerGender: TmkSpeakerGender = OneToOneDemoDefaults.online.leftSpeaker
    private var selectedRightSpeakerGender: TmkSpeakerGender = OneToOneDemoDefaults.online.rightSpeaker
    private var selectedTranslateEngine: TmkOnlineTranslateEngine = .fast
    private var selectedRecognizeEngine: TmkOnlineRecognizeEngine = .default
    private var selectedTranslateMode: TmkTranslateDeliveryMode = .default
    private var selectedScenarioOption: OneToOneScenarioOption = .defaultOption
    private var isScenarioUpdating = false
    private var pendingScenarioOption: OneToOneScenarioOption?
    private var pendingSourceLanguage: String?
    private var selectedChannelModeConfiguration: OneToOneChannelModeConfiguration = OneToOneStandardChannelModeConfiguration()
    private var selectedDialogConversationAudioMode: TmkDialogConversationAudioMode {
        selectedChannelModeConfiguration.audioMode
    }
    private var supportedLanguages: Set<String> = []
    private var isAuthVerified = false

    private let audioProcessQueue = DispatchQueue(label: "co.timekettle.demo.onetoone.audio")
    private let audioFrameBackpressure = DemoAudioFrameBackpressure(maxPendingBytes: maxPendingPlaybackAudioBytes)
    private let stateLock = NSLock()
    private var isListeningActive = false
    private var pendingAutoStartAfterRecreate = false
    private var cachedCaptureSampleRate: Int = -1
    private var cachedCaptureChannels: Int = -1
    private var cachedPlaybackChannels: Int = -1
    private var maxDisplayedRows = 20
    private lazy var localPCMData: Data? = {
        guard let path = Bundle.main.path(forResource: "right_audio", ofType: "pcm", inDirectory: "PCM")
            ?? Bundle.main.path(forResource: "right_audio", ofType: "pcm") else { return nil }
        return try? Data(contentsOf: URL(fileURLWithPath: path))
    }()
    private lazy var leftFileAudioLoopBuffer = OneToOneLocalAudioLoopBuffer(pcmData: localPCMData)
    private let networkEventPolicy = DemoOnlineNetworkEventPolicy()
    private let networkStatsTracker = DemoOnlineNetworkStatsTracker()
    private let bootstrapTracker = DemoBootstrapPipelineTracker()
    private let wifiSpeedProbe = DemoWifiSpeedProbe()
    private let reconnectTimeoutMonitor = DemoReconnectTimeoutMonitor()

    var currentLeftSpeakerGender: TmkSpeakerGender {
        selectedLeftSpeakerGender
    }

    var currentRightSpeakerGender: TmkSpeakerGender {
        selectedRightSpeakerGender
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
        updateStateOnMain {
            $0.sourceLanguage = self.selectedSourceLang
            $0.targetLanguage = self.selectedTargetLang
            $0.translateEngine = self.selectedTranslateEngine
            $0.recognizeEngine = self.selectedRecognizeEngine
            $0.translateMode = self.selectedTranslateMode
            $0.scenarioOption = self.selectedScenarioOption
            $0.dialogConversationAudioMode = self.selectedDialogConversationAudioMode
            $0.configuredChannels = self.selectedChannelModeConfiguration.pcmChannels
        }
        startWifiSpeedProbe()
        startOnlineListening()
    }

    func onViewWillClose() {
        reconnectTimeoutMonitor.cancel()
        cancelWifiSpeedProbe()
        stopListeningIfNeeded()
    }

    func recreateAfterRemoteClose() {
        reconnectTimeoutMonitor.cancel()
        guard hasStoppedListening else { return }
        hasStoppedListening = false
        updateStatus("正在重新创建通道...")
        startWifiSpeedProbe()
        startOnlineListening()
    }

    func startListening() {
        guard state.canStartListening, let channel else { return }
        if voiceIO == nil {
            voiceIO = TmkVoiceProcessingIO(config: TmkVPConfig(sampleRate: 16_000,
                                                               channels: 1,
                                                               bitsPerChannel: 16,
                                                               framesPerBuffer: 1024))
        }
        guard let voiceIO else { return }
        ttsCoordinator.attach(voiceIO: voiceIO)
        configureInterruptionHandling(for: voiceIO)

        do {
            try voiceIO.activateAudioSession(sampleRate: 16000,
                                             framesPerBuffer: 1024,
                                             mode: .voiceChat,
                                             useSpeaker: true)
        } catch {
            updateStatus("音频会话配置失败：\(error.localizedDescription)")
            return
        }

        voiceIO.onInputPCM = { [weak self, weak channel] data, format, _ in
            guard let self else { return }
            let micChannels = Int(format.mChannelsPerFrame)
            let micSampleRate = Int(format.mSampleRate)
            self.updateCaptureAudioInfo(sampleRate: micSampleRate, channels: micChannels)
            // VoiceProcessingIO 采集配置为单声道，当前 Demo 作为 right 路输入。
            let recordData = data.count.isMultiple(of: 2) ? data : Data(data.prefix(data.count - 1))
            guard recordData.isEmpty == false else { return }
            let fileChunk = self.nextLeftFileAudioChunk(expectedLength: recordData.count)
            guard let channel else { return }
            self.pushInputAudio(fileData: fileChunk.data, rightMicData: recordData, channel: channel)
        }

        voiceIO.requestRecordPermission { [weak self] granted in
            guard let self else { return }
            guard granted else {
                self.updateStatus("麦克风权限未授权")
                return
            }
            do {
                self.resetLocalPCMPlaybackState()
                try voiceIO.start()
                self.setListeningActive(true)
                self.ttsCoordinator.setActive(true)
                self.updateStateOnMain {
                    $0.canStopListening = true
                    $0.canStartListening = false
                }
                self.updateStatus("正在收听中...")
            } catch {
                self.updateStatus("开始收听失败：\(error.localizedDescription)")
            }
        }
    }

    func stopListening() {
        clearPendingAutoStartAfterRecreate()
        voiceIO?.stop()
        ttsCoordinator.setActive(false)
        resetLocalPCMPlaybackState()
        setListeningActive(false)
        activePlaybackUID = nil
        playbackLaneByUID.removeAll()
        updateStateOnMain {
            $0.canStopListening = false
            $0.canStartListening = self.channel != nil
            $0.networkStats = .init()
        }
        networkStatsTracker.reset()
        updateStatus("收听已停止")
    }

    /// 配置采集中断/恢复事件处理：来电等中断结束后录音器会自动恢复，这里仅同步 UI 文案。
    private func configureInterruptionHandling(for voiceIO: TmkVoiceProcessingIO) {
        voiceIO.onInterruptionEvent = { [weak self] event in
            guard let self else { return }
            switch event {
            case .interrupted:
                self.updateStatus("通话中断，已暂停收听...")
            case .resumed:
                self.updateStatus("正在收听中...")
            case .resumeFailed(let error):
                self.updateStatus("恢复收听失败，请重试：\(error.localizedDescription)")
                self.setListeningActive(false)
                self.updateStateOnMain {
                    $0.canStopListening = false
                    $0.canStartListening = self.channel != nil
                }
            }
        }
    }

    func setPlaybackMode(_ mode: OneToOnePlaybackMode) {
        ttsCoordinator.setPlaybackMode(mode)
        updateStateOnMain { $0.playbackMode = mode }
    }

    func fetchSupportedLanguages(
        _ completion: @escaping (Result<TmkLocaleListResponse, TmkTranslationError>) -> Void
    ) {
        _ = TmkTranslationSDK.shared.getOnlineSupportedLanguages { [weak self] result in
            guard let self else {
                completion(result)
                return
            }
            switch result {
            case .success(let response):
                self.supportedLanguages = Set(response.localeOptions.map(\.code))
                Self.logger.info("supported languages loaded count=\(self.supportedLanguages.count, privacy: .public)")
            case .failure(let error):
                self.updateStatus("获取支持语言失败：\(error.localizedDescription)")
                Self.logger.error("load supported languages failed: \(error.localizedDescription, privacy: .public)")
            }
            completion(result)
        }
    }

    func isSourceLanguageSelectable(_ source: String) -> Bool {
        OneToOneSameLanguagePolicy.isOnlineLanguageSelectable(
            source: source,
            target: selectedTargetLang,
            currentRoomScenario: selectedScenarioOption.roomScenario,
            pendingRoomScenario: pendingScenarioOption?.roomScenario
        )
    }

    func applySourceLanguage(_ source: String) {
        guard supportedLanguages.contains(source) else {
            updateStatus("语言不在支持列表中")
            return
        }
        if deferLanguageChangeIfScenarioUpdating(source: source, target: selectedTargetLang) {
            return
        }
        if let errorMessage = OneToOneSameLanguagePolicy.onlineLanguageChangeErrorMessage(
            source: source,
            target: selectedTargetLang,
            roomScenario: selectedScenarioOption.roomScenario,
            isScenarioUpdating: isScenarioUpdating
        ) {
            updateStatus(errorMessage)
            return
        }
        guard source != selectedSourceLang else { return }
        updateOneToOneLanguage(source: source)
    }

    func updateSpeaker(channel speakerChannel: TmkSpeakerChannel, gender: TmkSpeakerGender) {
        switch speakerChannel {
        case .left:
            selectedLeftSpeakerGender = gender
        case .right:
            selectedRightSpeakerGender = gender
        }
        let speaker = TmkSpeaker(channel: speakerChannel, gender: gender)
        guard let channel else {
            updateStatus("音色已保存，将在在线房间创建时生效")
            return
        }
        updateStatus("正在切换在线音色...")
        channel.updateSpeaker(speakers: [speaker]) { [weak self] result in
            switch result {
            case .success:
                self?.updateStatus("在线音色已切换，下一次合成生效")
            case .failure(let error):
                self?.updateStatus("在线音色切换失败：\(error.localizedDescription)")
            }
        }
    }

    func updateSpeakers(left: TmkSpeakerGender, right: TmkSpeakerGender) {
        selectedLeftSpeakerGender = left
        selectedRightSpeakerGender = right
        let speakers = [
            TmkSpeaker(channel: .left, gender: left),
            TmkSpeaker(channel: .right, gender: right)
        ]
        guard let channel else {
            updateStatus("音色已保存，将在在线房间创建时生效")
            return
        }
        updateStatus("正在切换在线音色...")
        channel.updateSpeaker(speakers: speakers) { [weak self] result in
            switch result {
            case .success:
                self?.updateStatus("在线左右声道音色已切换，下一次合成生效")
            case .failure(let error):
                self?.updateStatus("在线音色切换失败：\(error.localizedDescription)")
            }
        }
    }

    func updateTranslateEngine(_ translateEngine: TmkOnlineTranslateEngine) {
        selectedTranslateEngine = translateEngine
        updateStateOnMain {
            $0.translateEngine = translateEngine
        }
        guard let room else {
            updateStatus("翻译引擎已保存，将在在线房间创建时生效")
            return
        }
        updateStatus("正在切换翻译引擎...")
        _ = room.updateTranslateEngine(translateEngine) { [weak self] result in
            switch result {
            case .success:
                self?.updateStatus("翻译引擎已切换，下一句话生效")
            case .failure(let error):
                self?.updateStatus("翻译引擎切换失败：\(error.localizedDescription)")
            }
        }
    }

    func updateScenarioOption(_ option: OneToOneScenarioOption) {
        guard selectedScenarioOption != option else { return }
        guard !isScenarioUpdating else {
            updateStatus(OneToOneSameLanguagePolicy.scenarioUpdatingMessage)
            return
        }
        guard OneToOneSameLanguagePolicy.isOnlineAllowed(
            source: selectedSourceLang,
            target: selectedTargetLang,
            roomScenario: option.roomScenario
        ) else {
            updateStatus(OneToOneSameLanguagePolicy.requiresRecognizeMessage)
            return
        }
        guard let room else {
            selectedScenarioOption = option
            updateStateOnMain {
                $0.scenarioOption = option
            }
            updateStatus("房间能力已切换为\(option.title)，将在下次创建房间后生效")
            return
        }
        updateStatus("正在切换房间能力为\(option.title)...")
        isScenarioUpdating = true
        pendingScenarioOption = option
        _ = room.updateScenario(option.roomScenario) { [weak self] result in
            guard let self else { return }
            self.isScenarioUpdating = false
            self.pendingScenarioOption = nil
            switch result {
            case .success:
                self.selectedScenarioOption = option
                self.updateStateOnMain {
                    $0.scenarioOption = option
                }
                self.updateStatus("房间能力已切换为\(option.title)，下一句话生效")
                if let source = self.pendingSourceLanguage {
                    self.pendingSourceLanguage = nil
                    self.applySourceLanguage(source)
                }
            case .failure(let error):
                self.pendingSourceLanguage = nil
                self.updateStatus("房间能力切换失败：\(error.localizedDescription)")
            }
        }
    }

    private func deferLanguageChangeIfScenarioUpdating(source: String, target: String) -> Bool {
        guard isScenarioUpdating else { return false }
        guard let pendingScenarioOption,
              OneToOneSameLanguagePolicy.canQueueOnlineLanguageChange(
                  source: source,
                  target: target,
                  pendingRoomScenario: pendingScenarioOption.roomScenario
              ) else {
            updateStatus(OneToOneSameLanguagePolicy.scenarioUpdatingMessage)
            return true
        }
        pendingSourceLanguage = source
        updateStatus("房间能力切换中，完成后将自动切换语言")
        return true
    }

    func updateDialogConversationAudioMode(_ mode: TmkDialogConversationAudioMode) {
        guard selectedDialogConversationAudioMode != mode else { return }
        selectedChannelModeConfiguration = OneToOneChannelModeConfigurationFactory.make(mode: mode)
        updateStateOnMain {
            $0.dialogConversationAudioMode = mode
            $0.configuredChannels = self.selectedChannelModeConfiguration.pcmChannels
        }
        recreateRoomAndChannel(statusText: "在线一对一通道模式已切换，重新创建通道中...")
    }

    /// 识别引擎在创建房间时下发，切换后沿用通道模式的释放并重建流程使新引擎生效。
    func updateRecognizeEngine(_ recognizeEngine: TmkOnlineRecognizeEngine) {
        guard selectedRecognizeEngine != recognizeEngine else { return }
        selectedRecognizeEngine = recognizeEngine
        updateStateOnMain {
            $0.recognizeEngine = recognizeEngine
        }
        recreateRoomAndChannel(statusText: "在线一对一识别引擎已切换，重新创建通道中...")
    }

    /// 翻译下发模式在创建房间时下发，切换后沿用通道模式的释放并重建流程使新模式生效。
    func updateTranslateMode(_ translateMode: TmkTranslateDeliveryMode) {
        guard selectedTranslateMode != translateMode else { return }
        selectedTranslateMode = translateMode
        updateStateOnMain {
            $0.translateMode = translateMode
        }
        recreateRoomAndChannel(statusText: "在线一对一翻译下发模式已切换，重新创建通道中...")
    }
}

enum OneToOneSameLanguagePolicy {
    static let requiresRecognizeMessage = "相同语言仅支持单识别，请先切换房间能力"
    static let scenarioUpdatingMessage = "房间能力切换中，请完成后再切换语言"

    static func isOfflineAllowed(source: String, target: String, roomScenario: TmkRoomScenario) -> Bool {
        normalizedLanguageCode(source) != normalizedLanguageCode(target) || roomScenario == .recognize
    }

    static func isOnlineAllowed(source: String, target: String, roomScenario: TmkRoomScenario) -> Bool {
        source.caseInsensitiveCompare(target) != .orderedSame || roomScenario == .recognize
    }

    static func isOnlineLanguageSelectable(source: String,
                                           target: String,
                                           currentRoomScenario: TmkRoomScenario,
                                           pendingRoomScenario: TmkRoomScenario?) -> Bool {
        isOnlineAllowed(
            source: source,
            target: target,
            roomScenario: pendingRoomScenario ?? currentRoomScenario
        )
    }

    static func offlineLanguageChangeErrorMessage(source: String,
                                                  target: String,
                                                  roomScenario: TmkRoomScenario,
                                                  isScenarioUpdating: Bool) -> String? {
        if isScenarioUpdating {
            return scenarioUpdatingMessage
        }
        return isOfflineAllowed(source: source, target: target, roomScenario: roomScenario)
            ? nil
            : requiresRecognizeMessage
    }

    static func onlineLanguageChangeErrorMessage(source: String,
                                                 target: String,
                                                 roomScenario: TmkRoomScenario,
                                                 isScenarioUpdating: Bool) -> String? {
        if isScenarioUpdating {
            return scenarioUpdatingMessage
        }
        return isOnlineAllowed(source: source, target: target, roomScenario: roomScenario)
            ? nil
            : requiresRecognizeMessage
    }

    static func canQueueOfflineLanguageChange(source: String,
                                              target: String,
                                              pendingRoomScenario: TmkRoomScenario) -> Bool {
        isOfflineAllowed(source: source, target: target, roomScenario: pendingRoomScenario)
    }

    static func canQueueOnlineLanguageChange(source: String,
                                             target: String,
                                             pendingRoomScenario: TmkRoomScenario) -> Bool {
        isOnlineAllowed(source: source, target: target, roomScenario: pendingRoomScenario)
    }

    private static func normalizedLanguageCode(_ code: String) -> String {
        let trimmedCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
        let separator = trimmedCode.firstIndex(where: { $0 == "-" || $0 == "_" })
        return (separator.map { String(trimmedCode[..<$0]) } ?? trimmedCode).lowercased()
    }
}

enum DemoTmkResultLogFormatter {
    /// 逐条 ASR/MT 结果日志开关。默认关闭。
    ///
    /// 每个 ASR/MT partial 回调都会走到 [log]；新闻联播等长跑场景单句可产 300+ partial,
    /// 无门控地 `NSLog` + 全量字符串格式化(插值 + formatExtraData 的字典排序/map/join)在热路径上
    /// 持续占用 CPU,是离线 1v1 长跑设备发烫的成因之一(bug 7056638789)。默认关闭后,
    /// 长跑热路径不再产生格式化与同步系统调用开销;需要排查时再打开。
    static var isVerboseResultLoggingEnabled = false

    /// 惰性记录逐条结果日志:开关关闭时**完全跳过**闭包求值(不做任何字符串格式化)。
    /// - Parameter line: 日志内容的惰性构造闭包,仅在开关开启时才求值。
    static func log(_ line: @autoclosure () -> String) {
        guard isVerboseResultLoggingEnabled else { return }
        NSLog("%@", line())
    }

    static func makeLine(scene: String, stage: String, result: TmkResult<String>, isFinal: Bool) -> String {
        "[\(scene)][\(stage)][TmkResult] channel=\(channel(from: result)) lane=\(lane(from: result)) sessionId=\(result.sessionId) bubbleId=\(bubbleId(from: result)) srcCode=\(result.srcCode) dstCode=\(result.dstCode) isLast=\(result.isLast) isFinal=\(isFinal) data=\(result.data) extraData=\(formatExtraData(result.extraData))"
    }

    static func makeBubbleEndLine(scene: String,
                                  result: TmkResult<String>,
                                  affectedSnapshots: [DemoConversationBubbleSnapshot]) -> String {
        let affectedLanes = affectedSnapshots.map(\.lane.rawValue).sorted().joined(separator: ",")
        return "[\(scene)][BubbleEnd][TmkResult] channel=\(channel(from: result)) lane=\(lane(from: result)) sessionId=\(result.sessionId) bubbleId=\(bubbleId(from: result)) srcCode=\(result.srcCode) dstCode=\(result.dstCode) isLast=\(result.isLast) data=\(result.data) affectedRows=\(affectedSnapshots.count) affectedLanes=\(affectedLanes.isEmpty ? "-" : affectedLanes) extraData=\(formatExtraData(result.extraData))"
    }

    private static func bubbleId(from result: TmkResult<String>) -> String {
        if result.bubbleId.isEmpty == false {
            return result.bubbleId
        }
        if let bubbleId = result.extraData["bubble_id"] as? String, bubbleId.isEmpty == false {
            return bubbleId
        }
        if let bubbleId = result.extraData["bubbleId"] as? String, bubbleId.isEmpty == false {
            return bubbleId
        }
        return "sid_\(result.sessionId)"
    }

    private static func channel(from result: TmkResult<String>) -> String {
        if let channel = result.extraData["channel"] as? String, channel.isEmpty == false {
            return channel
        }
        return "-"
    }

    private static func lane(from result: TmkResult<String>) -> String {
        let channel = channel(from: result).lowercased()
        if channel == "left" || channel == "right" {
            return channel
        }
        return "-"
    }

    private static func formatExtraData(_ extraData: [String: Any]) -> String {
        guard extraData.isEmpty == false else { return "{}" }
        let pairs = extraData.keys.sorted().map { key in
            "\(key)=\(String(describing: extraData[key] ?? "nil"))"
        }
        return "{\(pairs.joined(separator: ", "))}"
    }
}

extension OneToOneViewModel {
    /// 供页面设置菜单展示当前临时保留数量。
    func currentBubbleRetentionLimit() -> Int { maxDisplayedRows }

    /// 仅作用于当前页面实例；确认后立即裁剪最旧气泡。
    func setBubbleRetentionLimit(_ limit: Int) {
        maxDisplayedRows = min(max(limit, DemoConversationBubbleAssembler.minimumMaxRows), DemoConversationBubbleAssembler.maximumMaxRows)
        _ = bubbleAssembler.setMaxRows(maxDisplayedRows)
        trimRowsIfNeeded()
        schedulePublishRows()
    }
}

private extension OneToOneViewModel {
    func startOnlineListening() {
        let startupStartedAt = Date()
        let authStartedAt = Date()
        publishBootstrap(bootstrapTracker.begin(.auth))
        updateStatus("正在鉴权...")
        TmkTranslationSDK.shared.verifyAuth { [weak self] result in
            guard let self else { return }
            let authDurationMs = self.durationMs(since: authStartedAt)
            switch result {
            case .success:
                self.isAuthVerified = true
                Self.logger.info("启动翻译耗时 鉴权耗时 authDurationMs=\(authDurationMs, privacy: .public) result=success")
                self.publishBootstrap(self.bootstrapTracker.complete(.auth))
                self.updateStatus("鉴权成功，准备创建房间...")
                self.createRoomAndChannel(startupStartedAt: startupStartedAt)
            case .failure(let error):
                self.isAuthVerified = false
                Self.logger.info("启动翻译耗时 鉴权耗时 authDurationMs=\(authDurationMs, privacy: .public) totalDurationMs=\(self.durationMs(since: startupStartedAt), privacy: .public) result=failure")
                self.publishBootstrap(self.bootstrapTracker.fail(.auth))
                self.updateStatus(DemoSDKConfigurationFactory.authFailureMessage(error))
            }
        }
    }

    func createRoomAndChannel(startupStartedAt: Date) {
        publishBootstrap(bootstrapTracker.begin(.createRoom))
        let roomConfig = TmkTranslationRoomConfig(
            sourceLang: selectedRightLang,
            targetLang: selectedLeftLang,
            scenario: selectedScenarioOption.roomScenario,
            channelScenario: .oneToOne,
            speakers: configuredSpeakers(),
            translateEngine: selectedTranslateEngine,
            recognizeEngine: selectedRecognizeEngine,
            translateMode: selectedTranslateMode,
            dialogConversationAudioMode: selectedDialogConversationAudioMode,
            enableSensitiveWordRedaction: DemoSettingsStore().loadCurrentConfig().sensitiveWordRedactionEnabled ? .enabled : .disabled
        )
        let roomStartedAt = Date()
        TmkTranslationSDK.shared.createTmkTranslationRoom(config: roomConfig) { [weak self] result in
            guard let self else { return }
            let roomDurationMs = self.durationMs(since: roomStartedAt)
            switch result {
            case .success(let room):
                Self.logger.info("启动翻译耗时 创建房间耗时 roomDurationMs=\(roomDurationMs, privacy: .public) result=success")
                self.publishBootstrap(self.bootstrapTracker.complete(.createRoom))
                self.createTranslationChannel(room: room, startupStartedAt: startupStartedAt)
            case .failure(let error):
                Self.logger.info("启动翻译耗时 创建房间耗时 roomDurationMs=\(roomDurationMs, privacy: .public) totalDurationMs=\(self.durationMs(since: startupStartedAt), privacy: .public) result=failure")
                self.publishBootstrap(self.bootstrapTracker.fail(.createRoom))
                self.updateStatus("房间创建失败：\(error.localizedDescription)")
            }
        }
    }

    func createTranslationChannel(room: TmkTranslationRoom, startupStartedAt: Date) {
        self.room = room
        refreshTargetPlaybackUIDs(from: room)
        let config = TmkTranslationChannelConfig.Builder()
            .setRoom(room)
            .setScenario(.oneToOne)
            .setMode(.online)
            .setSourceLang(selectedRightLang)
            .setTargetLang(selectedLeftLang)
            .setSpeakers(configuredSpeakers())
            .setPCMSampleRate(16_000)
            .setPCMChannels(selectedChannelModeConfiguration.pcmChannels)
            .build()

        updateStateOnMain {
            $0.currentRoomNo = room.channelDialogResponse?.roomNo ?? "-"
            $0.configuredSampleRate = config.pcmSampleRate
            $0.configuredChannels = config.pcmChannels
            $0.sourceLanguage = self.selectedSourceLang
            $0.targetLanguage = self.selectedTargetLang
        }

        let channelStartedAt = Date()
        publishBootstrap(bootstrapTracker.begin(.createChannel))
        TmkTranslationSDK.shared.createTranslationChannel(config) { [weak self] result in
            guard let self else { return }
            let channelDurationMs = self.durationMs(since: channelStartedAt)
            let totalDurationMs = self.durationMs(since: startupStartedAt)
            switch result {
            case .success(let channel):
                self.channel = channel
                channel.setTranslationListener(self)
                self.publishBootstrap(self.bootstrapTracker.beginChannelReady())
                let runtime = channel.currentRuntimeState().state
                if runtime == .running || runtime == .degraded {
                    self.publishBootstrap(self.bootstrapTracker.completeChannelReady())
                }
                let shouldResumeListening = self.consumePendingAutoStartAfterRecreate()
                self.updateStateOnMain {
                    $0.canStartListening = true
                    if shouldResumeListening {
                        DispatchQueue.main.async { [weak self] in
                            guard let self, self.hasStoppedListening == false else { return }
                            self.startListening()
                        }
                    }
                }
                Self.logger.info("启动翻译耗时 加入通道耗时 channelDurationMs=\(channelDurationMs, privacy: .public) totalDurationMs=\(totalDurationMs, privacy: .public) result=success")
                self.updateStatus("在线通道已就绪，点击“开始收听”开始采集")
            case .failure(let error):
                Self.logger.info("启动翻译耗时 加入通道耗时 channelDurationMs=\(channelDurationMs, privacy: .public) totalDurationMs=\(totalDurationMs, privacy: .public) result=failure")
                self.publishBootstrap(self.bootstrapTracker.fail(.createChannel))
                self.updateStatus("通道启动失败：\(error.localizedDescription)")
            }
        }
    }

    func stopListeningIfNeeded() {
        guard hasStoppedListening == false else { return }
        hasStoppedListening = true
        clearPendingAutoStartAfterRecreate()
        rowUpdateCoalescer.flushAll()
        rowUpdateCoalescer.cancelAll()
        pendingRowsPublishWorkItem?.cancel()
        pendingRowsPublishWorkItem = nil
        setListeningActive(false)
        voiceIO?.stop()
        ttsCoordinator.setActive(false)
        resetLocalPCMPlaybackState()
        voiceIO = nil
        TmkTranslationSDK.shared.releaseChannel()
        channel = nil
        room = nil
        activePlaybackUID = nil
        targetPlaybackUIDs.removeAll()
        playbackLaneByUID.removeAll()
        networkStatsTracker.reset()
        updateStateOnMain { $0.networkStats = .init() }
        updateStatus("已停止收听")
        Self.logger.info("oneToOne channel stopped")
    }

    func recreateRoomAndChannel(statusText: String = "语言已切换，重新创建通道中...") {
        setPendingAutoStartAfterRecreate(getListeningActive())
        networkStatsTracker.reset()
        voiceIO?.stop()
        ttsCoordinator.setActive(false)
        resetLocalPCMPlaybackState()
        setListeningActive(false)
        activePlaybackUID = nil
        targetPlaybackUIDs.removeAll()
        playbackLaneByUID.removeAll()
        TmkTranslationSDK.shared.releaseChannel()
        channel = nil
        room = nil
        hasStoppedListening = false
        resetRows()
        updateStateOnMain {
            $0.rows = []
            $0.canStartListening = false
            $0.canStopListening = false
            $0.playbackChannels = 0
            $0.currentRoomNo = "-"
            $0.networkStats = .init()
        }
        updateStatus(statusText)
        startOnlineListening()
    }

    func updateOneToOneLanguage(source: String) {
        guard let room else {
            selectedSourceLang = source
            activePlaybackUID = nil
            targetPlaybackUIDs.removeAll()
            playbackLaneByUID.removeAll()
            cachedPlaybackChannels = -1
            updateStateOnMain {
                $0.playbackChannels = 0
                $0.sourceLanguage = source
                $0.targetLanguage = self.selectedTargetLang
            }
            updateStatus("语言已切换，将在下次创建房间后生效")
            return
        }
        updateStatus("语言已切换，正在更新一对一房间语言，下一句话生效...")
        _ = updateOneToOneRoomLocale(room: room,
                                     rightLang: source,
                                     leftLang: selectedTargetLang) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.selectedSourceLang = source
                self.activePlaybackUID = nil
                self.targetPlaybackUIDs.removeAll()
                self.playbackLaneByUID.removeAll()
                self.cachedPlaybackChannels = -1
                self.channel?.updateLanguages(sourceLang: source, targetLang: self.selectedTargetLang)
                self.updateStateOnMain {
                    $0.playbackChannels = 0
                    $0.sourceLanguage = source
                    $0.targetLanguage = self.selectedTargetLang
                }
                self.updateStatus("一对一房间语言已更新，下一句话生效")
            case .failure(let error):
                self.updateStatus("更新一对一房间语言失败：\(error.localizedDescription)")
            }
        }
    }

    @discardableResult
    private func updateOneToOneRoomLocale(room: TmkTranslationRoom,
                                          rightLang: String,
                                          leftLang: String,
                                          completion: @escaping (Result<Void, TmkTranslationError>) -> Void) -> TmkSDKCancellable? {
        room.updateRoomLocale(sourceLocales: [leftLang],
                              targetLocales: [rightLang],
                              completion: completion)
    }

    func configuredSpeakers() -> [TmkSpeaker] {
        [
            TmkSpeaker(channel: .left, gender: selectedLeftSpeakerGender),
            TmkSpeaker(channel: .right, gender: selectedRightSpeakerGender)
        ]
    }

    func pushInputAudio(fileData: Data, rightMicData: Data, channel: TmkTranslationChannel) {
        let pushPlans = selectedChannelModeConfiguration.makeInputAudioPushPlan(fileData: fileData,
                                                                                rightMicData: rightMicData)
        for plan in pushPlans {
            switch plan.destination {
            case .interleaved(let channelCount):
                channel.pushStreamAudioData(plan.data, channelCount: channelCount, extraChunk: nil)
            case .speaker(let speakerChannel):
                channel.pushStreamAudioData(plan.data, speakerChannel: speakerChannel, extraChunk: nil)
            }
        }
    }

    func updateStatus(_ text: String) {
        updateStateOnMain { $0.statusText = text }
    }

    func durationMs(since startAt: Date) -> Int {
        Int(Date().timeIntervalSince(startAt) * 1000)
    }

    func publishBootstrap(_ snapshot: DemoBootstrapSnapshot) {
        updateStateOnMain { $0.bootstrapStats = snapshot }
    }

    func startWifiSpeedProbe() {
        let baseURL = DemoWifiSpeedProbe.resolvedBusinessBaseURL()
        wifiSpeedProbe.start(businessBaseURL: baseURL) { [weak self] snapshot in
            self?.updateStateOnMain { $0.wifiSpeed = snapshot }
        }
    }

    func cancelWifiSpeedProbe() {
        wifiSpeedProbe.cancel()
        updateStateOnMain {
            if $0.wifiSpeed.status == .running || $0.wifiSpeed.status == .idle {
                $0.wifiSpeed.status = .cancelled
            }
        }
    }

    func updateStateOnMain(_ action: @escaping (inout OneToOneViewState) -> Void) {
        DispatchQueue.main.async {
            var newState = self.state
            action(&newState)
            self.state = newState
        }
    }

    func resetRows() {
        rowUpdateCoalescer.cancelAll()
        rows.removeAll()
        rowIndexMap.removeAll()
        bubbleLaneMap.removeAll()
        rawSessionRowKey.removeAll()
        rawChunkRowKey.removeAll()
        blueSessions.removeAll()
        blueChunks.removeAll()
        bubbleAssembler.reset()
        lastPublishedRows.removeAll()
        pendingRowsPublishWorkItem?.cancel()
        pendingRowsPublishWorkItem = nil
        rowMutation.send(.reset(rows: []))
    }

    func updateCaptureAudioInfo(sampleRate: Int, channels: Int) {
        guard cachedCaptureSampleRate != sampleRate || cachedCaptureChannels != channels else { return }
        cachedCaptureSampleRate = sampleRate
        cachedCaptureChannels = channels
        updateStateOnMain {
            guard $0.captureSampleRate != sampleRate || $0.captureChannels != channels else { return }
            $0.captureSampleRate = sampleRate
            $0.captureChannels = channels
        }
    }

    func updatePlaybackChannel(_ channels: Int) {
        guard cachedPlaybackChannels != channels else { return }
        cachedPlaybackChannels = channels
        updateStateOnMain {
            guard $0.playbackChannels != channels else { return }
            $0.playbackChannels = channels
        }
    }

    func rowKey(bubbleId: String, lane: OneToOneRowViewData.Lane) -> String {
        "\(bubbleId)_\(lane.rawValue)"
    }

    func applyBubbleSnapshot(_ snapshot: DemoConversationBubbleSnapshot) {
        if Thread.isMainThread {
            applyBubbleSnapshotOnMain(snapshot)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.applyBubbleSnapshotOnMain(snapshot)
            }
        }
    }

    /// SDK 已保证结果回调在主线程；直接应用避免每个 partial 再创建一个主线程任务而形成快照积压。
    private func applyBubbleSnapshotOnMain(_ snapshot: DemoConversationBubbleSnapshot) {
        dispatchPrecondition(condition: .onQueue(.main))
        let lane: OneToOneRowViewData.Lane = snapshot.lane == .right ? .right : .left
        let key = rowKey(bubbleId: snapshot.bubbleId, lane: lane)
        indexSessions(of: snapshot, key: key)
        if let rowIndex = rowIndexMap[key], rows.indices.contains(rowIndex) {
            var row = rows[rowIndex]
            row.sessionId = snapshot.sessionId
            row.sourceLangCode = snapshot.sourceLangCode
            row.targetLangCode = snapshot.targetLangCode
            row.sourceText = snapshot.sourceText
            row.translatedText = snapshot.translatedText
            row.sourceSegments = highlightedSource(snapshot.sourceSegments)
            row.translatedSegments = highlightedTranslated(snapshot.translatedSegments)
            row.isBubbleEnded = snapshot.isBubbleEnded
            row.bOffset = snapshot.bOffset
            row.bDuration = snapshot.bDuration
            rows[rowIndex] = row
            rowUpdateCoalescer.submit(key)
            if snapshot.isBubbleEnded {
                rowUpdateCoalescer.flush(key)
            }
        } else {
            let row = OneToOneRowViewData(sessionId: snapshot.sessionId,
                                          bubbleId: snapshot.bubbleId,
                                          lane: lane,
                                          sourceLangCode: snapshot.sourceLangCode,
                                          targetLangCode: snapshot.targetLangCode,
                                          sourceText: snapshot.sourceText,
                                          translatedText: snapshot.translatedText,
                                          sourceSegments: highlightedSource(snapshot.sourceSegments),
                                          translatedSegments: highlightedTranslated(snapshot.translatedSegments),
                                          isBubbleEnded: snapshot.isBubbleEnded,
                                          bOffset: snapshot.bOffset,
                                          bDuration: snapshot.bDuration)
            rows.append(row)
            let rowIndex = rows.count - 1
            rowIndexMap[key] = rowIndex
            rowMutation.send(.insert(row: row, index: rowIndex))
        }
        trimRowsIfNeeded()
        schedulePublishRows()
    }

    /// UI 刷新时重新读取 rows 中的最新值，避免调度窗口持有多份中间文本快照。
    func publishLatestRows(for keys: [String]) {
        dispatchPrecondition(condition: .onQueue(.main))
        for key in keys {
            guard let rowIndex = rowIndexMap[key], rows.indices.contains(rowIndex) else { continue }
            rowMutation.send(.update(row: rows[rowIndex], index: rowIndex, heightMayChange: true))
        }
    }

    /// 源语言片段按 blueSessions（session_id）计算高亮。
    func highlightedSource(_ segments: [DemoConversationDisplaySegment]) -> [DemoConversationDisplaySegment] {
        segments.map { segment in
            var copy = segment
            copy.isHighlighted = blueSessions.isEmpty == false
                && segment.rawSessionIds.isDisjoint(with: blueSessions) == false
            return copy
        }
    }

    /// 目标语言片段按 blueChunks（chunk_id）计算高亮。
    func highlightedTranslated(_ segments: [DemoConversationDisplaySegment]) -> [DemoConversationDisplaySegment] {
        segments.map { segment in
            var copy = segment
            copy.isHighlighted = blueChunks.isEmpty == false
                && segment.rawChunkIds.isDisjoint(with: blueChunks) == false
            return copy
        }
    }

    /// 用快照里每段的 rawSessionIds / rawChunkIds 建立 → rowKey 映射，保证与行 key 完全一致。
    func indexSessions(of snapshot: DemoConversationBubbleSnapshot, key: String) {
        for segment in snapshot.sourceSegments + snapshot.translatedSegments {
            for rawId in segment.rawSessionIds {
                rawSessionRowKey[rawId] = key
            }
            for chunkId in segment.rawChunkIds {
                rawChunkRowKey[chunkId] = key
            }
        }
    }

    /// 收到 online_tts_state：按 is_end 着色（false→蓝，true→默认）。
    /// 源文按 session_id 命中，译文按 chunk_id 命中；重渲染命中的行。
    func applyTTSHighlight(sessionId: Int, chunkId: String?, isEnd: Bool) {
        DispatchQueue.main.async {
            if isEnd {
                self.blueSessions.remove(sessionId)
                if let chunkId, chunkId.isEmpty == false { self.blueChunks.remove(chunkId) }
            } else {
                self.blueSessions.insert(sessionId)
                if let chunkId, chunkId.isEmpty == false { self.blueChunks.insert(chunkId) }
            }
            var keys = Set<String>()
            if let key = self.rawSessionRowKey[sessionId] { keys.insert(key) }
            if let chunkId, let key = self.rawChunkRowKey[chunkId] { keys.insert(key) }
            for key in keys {
                guard let idx = self.rowIndexMap[key], self.rows.indices.contains(idx) else { continue }
                var row = self.rows[idx]
                row.sourceSegments = self.highlightedSource(row.sourceSegments)
                row.translatedSegments = self.highlightedTranslated(row.translatedSegments)
                guard row != self.rows[idx] else { continue }
                self.rows[idx] = row
                self.rowMutation.send(.update(row: row, index: idx, heightMayChange: false))
            }
            self.schedulePublishRows()
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
            let key = rowKey(bubbleId: row.bubbleId, lane: row.lane)
            newIndexMap[key] = index
        }
        rowIndexMap = newIndexMap
        rebuildBubbleLaneMap()
        // 收敛 session/chunk 相关字典/集合到当前仍存在的行，避免无限增长。
        let liveSegments = rows.flatMap { $0.sourceSegments + $0.translatedSegments }
        let liveSessions = Set(liveSegments.flatMap { $0.rawSessionIds })
        let liveChunks = Set(liveSegments.flatMap { $0.rawChunkIds })
        rawSessionRowKey = rawSessionRowKey.filter { liveSessions.contains($0.key) }
        rawChunkRowKey = rawChunkRowKey.filter { liveChunks.contains($0.key) }
        blueSessions.formIntersection(liveSessions)
        blueChunks.formIntersection(liveChunks)
    }

    func schedulePublishRows() {
        pendingRowsPublishWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.lastPublishedRows != self.rows else { return }
            self.lastPublishedRows = self.rows
            self.updateStateOnMain { $0.rows = self.rows }
        }
        pendingRowsPublishWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.rowUpdateInterval, execute: workItem)
    }

    func rebuildBubbleLaneMap() {
        var activeBubbleIDs = Set<String>()
        for row in rows {
            activeBubbleIDs.insert(row.bubbleId)
        }
        bubbleLaneMap = bubbleLaneMap.filter { activeBubbleIDs.contains($0.key) }
    }

    func lane(from result: TmkResult<String>) -> OneToOneRowViewData.Lane? {
        if let channel = (result.extraData["channel"] as? String)?.lowercased() {
            return parseLane(channel: channel)
        }
        return nil
    }

    func parseLane(channel: String) -> OneToOneRowViewData.Lane? {
        if channel == OneToOneRowViewData.Lane.left.rawValue { return .left }
        if channel == OneToOneRowViewData.Lane.right.rawValue { return .right }
        return nil
    }

    func resolveLane(bubbleId: String,
                     sessionId: Int,
                     explicitLane: OneToOneRowViewData.Lane?,
                     sourceLangCode: String,
                     targetLangCode: String) -> OneToOneRowViewData.Lane {
        if let explicitLane {
            bubbleLaneMap[bubbleId] = explicitLane
            return explicitLane
        }
        if let lane = bubbleLaneMap[bubbleId] {
            return lane
        }
        _ = sessionId
        let sourceLower = sourceLangCode.lowercased()
        let targetLower = targetLangCode.lowercased()
        let inferred: OneToOneRowViewData.Lane
        if sourceLower.hasPrefix(sourceLanguagePrefix()) || targetLower.hasPrefix(targetLanguagePrefix()) {
            inferred = .right
        } else {
            inferred = .left
        }
        bubbleLaneMap[bubbleId] = inferred
        return inferred
    }

    func fixedLanguagePair(for lane: OneToOneRowViewData.Lane) -> (source: String, target: String) {
        switch lane {
        case .right:
            return (selectedSourceLang, selectedTargetLang)
        case .left:
            return (selectedTargetLang, selectedSourceLang)
        }
    }

    func normalizedConversationEvent(from event: DemoConversationEvent,
                                     explicitLane: OneToOneRowViewData.Lane?) -> DemoConversationEvent {
        let lane = resolveLane(bubbleId: event.bubbleId,
                               sessionId: event.sessionId,
                               explicitLane: explicitLane,
                               sourceLangCode: event.sourceLangCode,
                               targetLangCode: event.targetLangCode)
        let demoLane: DemoConversationLane = lane == .right ? .right : .left
        let languagePair = fixedLanguagePair(for: lane)
        return DemoConversationEvent(bubbleId: event.bubbleId,
                                     sessionId: event.sessionId,
                                     lane: demoLane,
                                     stage: event.stage,
                                     isFinal: event.isFinal,
                                     text: event.text,
                                     sourceLangCode: languagePair.source,
                                     targetLangCode: languagePair.target,
                                     chunkId: event.chunkId,
                                     offset: event.offset,
                                     duration: event.duration)
    }

    func refreshTargetPlaybackUIDs(from room: TmkTranslationRoom) {
        guard let dialog = room.channelDialogResponse else {
            targetPlaybackUIDs = []
            return
        }
        let selfUID = Int(dialog.connectUid)
        let speakerUID = Int(dialog.speakerIdentityNo)
        let isSelfUID: (Int) -> Bool = { uid in
            uid == selfUID || uid == speakerUID
        }
        let preferred = dialog.translationList
            .filter { $0.locale.lowercased().hasPrefix(targetLanguagePrefix()) }
            .compactMap { Int($0.subscribeUid) }
            .filter { isSelfUID($0) == false }
        let nonSourceFallback = dialog.translationList
            .filter { $0.locale.lowercased().hasPrefix(sourceLanguagePrefix()) == false }
            .compactMap { Int($0.subscribeUid) }
            .filter { isSelfUID($0) == false }
        targetPlaybackUIDs = Set(preferred.isEmpty ? nonSourceFallback : preferred)
        activePlaybackUID = targetPlaybackUIDs.first
        playbackLaneByUID = makePlaybackLaneMap(from: dialog)
    }

    func makePlaybackLaneMap(from dialog: TmkTranslationRoomDialogResponse) -> [Int: OneToOneRowViewData.Lane] {
        var laneByUID: [Int: OneToOneRowViewData.Lane] = [:]
        for speaker in dialog.speakers {
            guard let uid = Int(speaker.subscribeUid),
                  let lane = parseLane(channel: speaker.channel.lowercased()) else {
                continue
            }
            laneByUID[uid] = lane
        }
        if laneByUID.isEmpty == false {
            return laneByUID
        }
        for item in dialog.translationList {
            guard let uid = Int(item.subscribeUid) else { continue }
            if item.locale.lowercased().hasPrefix(sourceLanguagePrefix()) {
                laneByUID[uid] = .right
            } else if item.locale.lowercased().hasPrefix(targetLanguagePrefix()) {
                laneByUID[uid] = .left
            }
        }
        return laneByUID
    }

    func sourceLanguagePrefix() -> String {
        String(selectedSourceLang.split(separator: "-").first ?? "").lowercased()
    }

    func targetLanguagePrefix() -> String {
        String(selectedTargetLang.split(separator: "-").first ?? "").lowercased()
    }

    func isSelfAudioUID(_ uid: Int) -> Bool {
        guard let dialog = room?.channelDialogResponse else { return false }
        return uid == Int(dialog.connectUid) || uid == Int(dialog.speakerIdentityNo)
    }

    func resetLocalPCMPlaybackState() {
        leftFileAudioLoopBuffer.reset()
    }

    func nextLeftFileAudioChunk(expectedLength: Int) -> OneToOneLocalAudioLoopChunk {
        leftFileAudioLoopBuffer.nextLoopChunk(expectedLength: expectedLength)
    }

    func audioUID(from result: TmkResult<String>) -> Int? {
        let uidValue = result.extraData["uid"]
        if let intValue = uidValue as? Int { return intValue }
        if let uintValue = uidValue as? UInt { return Int(uintValue) }
        if let strValue = uidValue as? String { return Int(strValue) }
        return result.sessionId > 0 ? result.sessionId : nil
    }

    func setListeningActive(_ active: Bool) {
        stateLock.lock()
        isListeningActive = active
        stateLock.unlock()
        if active == false {
            audioFrameBackpressure.invalidate()
        }
    }

    func setPendingAutoStartAfterRecreate(_ pending: Bool) {
        stateLock.lock()
        pendingAutoStartAfterRecreate = pending
        stateLock.unlock()
    }

    func consumePendingAutoStartAfterRecreate() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        let pending = pendingAutoStartAfterRecreate
        pendingAutoStartAfterRecreate = false
        return pending
    }

    func clearPendingAutoStartAfterRecreate() {
        setPendingAutoStartAfterRecreate(false)
    }

    func getListeningActive() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return isListeningActive
    }

    func applyRuntimeAction(_ action: DemoConversationRuntimeAction) {
        switch action {
        case .none, .ignore:
            return
        case .status(let text),
             .weakNetwork(let text),
             .reconnecting(let text):
            updateStatus(text)
        case .prompt(let prompt):
            reconnectTimeoutMonitor.cancel()
            DispatchQueue.main.async { [weak self] in
                self?.dismissReconnectTimeoutPrompt.send()
            }
            stopConversationForPrompt(status: prompt.title)
            DispatchQueue.main.async { [weak self] in
                self?.remoteCloseRoomPrompt.send(prompt)
            }
        }
    }

    func stopConversationForPrompt(status: String) {
        guard hasStoppedListening == false else {
            updateStatus(status)
            return
        }
        hasStoppedListening = true
        clearPendingAutoStartAfterRecreate()
        pendingRowsPublishWorkItem?.cancel()
        pendingRowsPublishWorkItem = nil
        setListeningActive(false)
        voiceIO?.stop()
        ttsCoordinator.setActive(false)
        resetLocalPCMPlaybackState()
        voiceIO = nil
        TmkTranslationSDK.shared.releaseChannel()
        channel = nil
        room = nil
        activePlaybackUID = nil
        targetPlaybackUIDs.removeAll()
        playbackLaneByUID.removeAll()
        cachedCaptureSampleRate = -1
        cachedCaptureChannels = -1
        cachedPlaybackChannels = -1
        updateStateOnMain {
            $0.canStartListening = false
            $0.canStopListening = false
            $0.currentRoomNo = "-"
            $0.captureSampleRate = 0
            $0.captureChannels = 0
            $0.playbackChannels = 0
        }
        updateStatus(status)
    }
}

extension OneToOneViewModel: TmkTranslationListener {
    func onRecognized(from engine: AbstractChannelEngine, result: TmkResult<String>, isFinal: Bool) {
        _ = engine
        DemoTmkResultLogFormatter.log(DemoTmkResultLogFormatter.makeLine(scene: "Online1V1", stage: "ASR", result: result, isFinal: isFinal))
        guard let event = DemoConversationEventAdapter.makeRecognizedEvent(from: result, isFinal: isFinal) else { return }
        let normalized = normalizedConversationEvent(from: event, explicitLane: lane(from: result))
        let snapshots = bubbleAssembler.consume(normalized)
        guard snapshots.isEmpty == false else { return }
        snapshots.forEach(applyBubbleSnapshot)
    }

    func onTranslate(from engine: AbstractChannelEngine, result: TmkResult<String>, isFinal: Bool) {
        _ = engine
        DemoTmkResultLogFormatter.log(DemoTmkResultLogFormatter.makeLine(scene: "Online1V1", stage: "MT", result: result, isFinal: isFinal))
        guard let event = DemoConversationEventAdapter.makeTranslatedEvent(from: result, isFinal: isFinal) else { return }
        let normalized = normalizedConversationEvent(from: event, explicitLane: lane(from: result))
        let snapshots = bubbleAssembler.consume(normalized)
        guard snapshots.isEmpty == false else { return }
        snapshots.forEach(applyBubbleSnapshot)
    }

    func onAudioDataReceive(from engine: AbstractChannelEngine, result: TmkResult<String>, data: Data, channelCount: Int) {
        _ = engine
        ttsCoordinator.handleAudioData(result: result, data: data, channelCount: channelCount)
    }

    func onError(_ error: TmkTranslationError) {
        applyRuntimeAction(DemoConversationRuntimePolicy.action(for: error))
    }

    func onEvent(name: String, args: Any?) {
        if DemoConversationRuntimePolicy.isCloseRoomEvent(name: name, args: args) {
            handleRemoteCloseRoom()
            return
        }

        if let snapshot = networkStatsTracker.consume(eventName: name, args: args) {
            updateStateOnMain { $0.networkStats = snapshot }
        }

        let networkAction = networkEventPolicy.action(forEvent: name, args: args)
        if networkAction != .none {
            applyRuntimeAction(networkAction)
            return
        }
        if name == "online_bubble_end",
           let result = args as? TmkResult<String> {
            let snapshots = bubbleAssembler.markBubbleEnded(bubbleId: result.bubbleId)
            DemoTmkResultLogFormatter.log(DemoTmkResultLogFormatter.makeBubbleEndLine(scene: "Online1V1",
                                                                     result: result,
                                                                     affectedSnapshots: snapshots))
            snapshots.forEach(applyBubbleSnapshot)
            return
        }
        if name == "online_tts_state",
           let result = args as? TmkResult<String> {
            DemoTmkResultLogFormatter.log(DemoTmkResultLogFormatter.makeLine(scene: "Online1V1",
                                                           stage: "TTSState",
                                                           result: result,
                                                           isFinal: result.isLast))
            let isEnd = (result.extraData["is_end"] as? Bool) ?? result.isLast
            let chunk = result.extraData["chunk_id"] as? String
            applyTTSHighlight(sessionId: result.sessionId, chunkId: chunk, isEnd: isEnd)
            return
        }
        if name == "online_started" {
            updateStatus("在线通道已就绪，点击“开始收听”开始采集")
        }
    }

    func onStateChanged(from engine: AbstractChannelEngine, snapshot: TmkTranslationChannelStateSnapshot) {
        _ = engine
        reconnectTimeoutMonitor.onStateChanged(snapshot.state) { [weak self] in
            self?.presentReconnectTimeoutPrompt()
        }
        if snapshot.state != .reconnecting {
            DispatchQueue.main.async { [weak self] in
                self?.dismissReconnectTimeoutPrompt.send()
            }
        }
        switch snapshot.state {
        case .running, .degraded:
            publishBootstrap(bootstrapTracker.completeChannelReady())
        case .failed:
            if bootstrapTracker.current().isRunning {
                publishBootstrap(bootstrapTracker.fail(.channelReady))
            }
        default:
            break
        }
        applyRuntimeAction(DemoConversationRuntimePolicy.action(for: snapshot,
                                                                isListening: getListeningActive()))
    }

    func continueWaitingAfterReconnectTimeout() {
        reconnectTimeoutMonitor.continueWaiting { [weak self] in
            self?.presentReconnectTimeoutPrompt()
        }
    }

    func recreateAfterReconnectTimeout() {
        reconnectTimeoutMonitor.cancel()
        stopListeningIfNeeded()
        recreateAfterRemoteClose()
    }

    private func presentReconnectTimeoutPrompt() {
        let prompt = DemoConversationPrompt(
            title: "连接恢复超时",
            message: "连接已断开，正在尝试自动恢复，但暂未恢复。你可以立即重新创建房间，也可以继续等待自动重连。",
            style: .reconnectTimeout
        )
        DispatchQueue.main.async { [weak self] in
            self?.remoteCloseRoomPrompt.send(prompt)
        }
    }

    private func handleRemoteCloseRoom() {
        reconnectTimeoutMonitor.cancel()
        DispatchQueue.main.async { [weak self] in
            self?.dismissReconnectTimeoutPrompt.send()
        }
        guard hasStoppedListening == false else { return }
        hasStoppedListening = true
        clearPendingAutoStartAfterRecreate()
        pendingRowsPublishWorkItem?.cancel()
        pendingRowsPublishWorkItem = nil
        setListeningActive(false)
        voiceIO?.stop()
        ttsCoordinator.setActive(false)
        resetLocalPCMPlaybackState()
        voiceIO = nil
        TmkTranslationSDK.shared.releaseChannel()
        channel = nil
        room = nil
        activePlaybackUID = nil
        targetPlaybackUIDs.removeAll()
        playbackLaneByUID.removeAll()
        cachedCaptureSampleRate = -1
        cachedCaptureChannels = -1
        cachedPlaybackChannels = -1
        updateStateOnMain {
            $0.canStartListening = false
            $0.canStopListening = false
            $0.currentRoomNo = "-"
            $0.captureSampleRate = 0
            $0.captureChannels = 0
            $0.playbackChannels = 0
            $0.networkStats = .init()
        }
        networkStatsTracker.reset()
        updateStatus("房间已关闭")
        Self.logger.info("oneToOne remote close_room received, waiting for user decision")
        let prompt = DemoConversationPrompt(
            title: "房间已关闭",
            message: "服务端已关闭当前房间，是否重新创建对话通道？",
            style: .restart
        )
        DispatchQueue.main.async { [weak self] in
            self?.remoteCloseRoomPrompt.send(prompt)
        }
    }
}
