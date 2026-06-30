import Foundation
import Combine
import OSLog
import TmkTranslationSDK
import AVFoundation

final class OneToOneViewModel: NSObject {
    private static let logger = Logger(subsystem: "co.timekettle.demo", category: "OneToOne")
    private enum PCMKind: String {
        case stereo
        case left
        case right
    }

    private struct PCMFileKey: Hashable {
        let uid: Int
        let kind: PCMKind
    }

    @Published private(set) var state = OneToOneViewState()
    let rowMutation = PassthroughSubject<ChatListMutation<OneToOneRowViewData>, Never>()
    let remoteCloseRoomPrompt = PassthroughSubject<DemoConversationPrompt, Never>()

    private var room: TmkTranslationRoom?
    private var channel: TmkTranslationChannel?
    private var voiceIO: TmkVoiceProcessingIO?
    private var hasStoppedListening = false
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
    private let bubbleAssembler = DemoConversationBubbleAssembler()
    private var pendingRowsPublishWorkItem: DispatchWorkItem?
    private var lastPublishedRows: [OneToOneRowViewData] = []

    private var targetPlaybackUIDs: Set<Int> = []
    private var activePlaybackUID: Int?
    private var playbackLaneByUID: [Int: OneToOneRowViewData.Lane] = [:]
    private var selectedSourceLang = "zh-CN"
    private var selectedTargetLang = "en-US"
    private var selectedRightLang: String { selectedSourceLang }
    private var selectedLeftLang: String { selectedTargetLang }
    private var selectedLeftSpeakerGender: TmkSpeakerGender = .male
    private var selectedRightSpeakerGender: TmkSpeakerGender = .female
    private var selectedTranslateEngine: TmkOnlineTranslateEngine = .accurate
    private var selectedScenarioOption: OneToOneScenarioOption = .defaultOption
    private var selectedChannelModeConfiguration: OneToOneChannelModeConfiguration = OneToOneStandardChannelModeConfiguration()
    private var selectedDialogConversationAudioMode: TmkDialogConversationAudioMode {
        selectedChannelModeConfiguration.audioMode
    }
    private var supportedLanguages: Set<String> = []
    private var isAuthVerified = false

    private let audioProcessQueue = DispatchQueue(label: "co.timekettle.demo.onetoone.audio")
    private let stateLock = NSLock()
    private var isListeningActive = false
    private var isCaptureEnabled = false
    private var playbackMode: OneToOnePlaybackMode = .left
    private var cachedCaptureSampleRate: Int = -1
    private var cachedCaptureChannels: Int = -1
    private var cachedPlaybackChannels: Int = -1
    private let maxDisplayedRows = 200
    private var hasPCMData = false
    private var isPCMRecordingEnabled = false
    private var pcmOutputDirectory: URL?
    private var pcmFileHandles: [PCMFileKey: FileHandle] = [:]
    private var pcmFileURLs: [PCMFileKey: URL] = [:]
    private lazy var localPCMData: Data? = {
        guard let path = Bundle.main.path(forResource: "right_audio", ofType: "pcm", inDirectory: "PCM")
            ?? Bundle.main.path(forResource: "right_audio", ofType: "pcm") else { return nil }
        return try? Data(contentsOf: URL(fileURLWithPath: path))
    }()
    private lazy var leftFileAudioLoopBuffer = OneToOneLocalAudioLoopBuffer(pcmData: localPCMData)
    private let networkEventPolicy = DemoOnlineNetworkEventPolicy()

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
            $0.isCaptureEnabled = self.isCaptureEnabled
            $0.sourceLanguage = self.selectedSourceLang
            $0.targetLanguage = self.selectedTargetLang
            $0.translateEngine = self.selectedTranslateEngine
            $0.scenarioOption = self.selectedScenarioOption
            $0.dialogConversationAudioMode = self.selectedDialogConversationAudioMode
            $0.configuredChannels = self.selectedChannelModeConfiguration.pcmChannels
        }
        startOnlineListening()
    }

    func onViewWillClose() {
        stopListeningIfNeeded()
    }

    func recreateAfterRemoteClose() {
        guard hasStoppedListening else { return }
        hasStoppedListening = false
        updateStatus("正在重新创建通道...")
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
                if self.isPCMRecordingEnabled {
                    self.preparePCMOutputDirectory()
                }
                self.resetLocalPCMPlaybackState()
                try voiceIO.start()
                self.setListeningActive(true)
                self.updateStateOnMain {
                    $0.canStopListening = true
                    $0.canStartListening = false
                    $0.canSharePCM = false
                }
                self.updateStatus("正在收听中...")
            } catch {
                self.updateStatus("开始收听失败：\(error.localizedDescription)")
            }
        }
    }

    func stopListening() {
        voiceIO?.stop()
        closeAllPCMFiles()
        resetLocalPCMPlaybackState()
        setListeningActive(false)
        activePlaybackUID = nil
        playbackLaneByUID.removeAll()
        updateStateOnMain {
            $0.canStopListening = false
            $0.canStartListening = self.channel != nil
            $0.canSharePCM = self.hasPCMData
        }
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

    var currentPCMURLs: [URL] {
        Array(pcmFileURLs.values).sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    @discardableResult
    func enablePCMRecordingIfNeeded() -> Bool {
        if isPCMRecordingEnabled { return false }
        isPCMRecordingEnabled = true
        if getListeningActive(), pcmOutputDirectory == nil {
            preparePCMOutputDirectory()
        }
        updateStatus("已开启PCM录制，请先进行对话后再分享")
        return true
    }

    func setPlaybackMode(_ mode: OneToOnePlaybackMode) {
        stateLock.lock()
        playbackMode = mode
        stateLock.unlock()
        voiceIO?.clearPlaybackBuffer()
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

    func applySourceLanguage(_ source: String) {
        guard supportedLanguages.contains(source) else {
            updateStatus("语言不在支持列表中")
            return
        }
        guard source.lowercased().hasPrefix(targetLanguagePrefix()) == false else {
            updateStatus("源语言不能与目标语言一致")
            return
        }
        guard source != selectedSourceLang else { return }
        updateOneToOneLanguage(source: source)
    }

    func setCaptureEnabled(_ enabled: Bool) {
        stateLock.lock()
        isCaptureEnabled = enabled
        stateLock.unlock()
        isPCMRecordingEnabled = enabled
        if enabled, getListeningActive(), pcmOutputDirectory == nil {
            preparePCMOutputDirectory()
        }
        if enabled == false {
            closeAllPCMFiles()
        }
        updateStateOnMain { $0.isCaptureEnabled = enabled }
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
        guard let room else {
            selectedScenarioOption = option
            updateStateOnMain {
                $0.scenarioOption = option
            }
            updateStatus("房间能力已切换为\(option.title)，将在下次创建房间后生效")
            return
        }
        updateStatus("正在切换房间能力为\(option.title)...")
        _ = room.updateScenario(option.roomScenario) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.selectedScenarioOption = option
                self.updateStateOnMain {
                    $0.scenarioOption = option
                }
                self.updateStatus("房间能力已切换为\(option.title)，下一句话生效")
            case .failure(let error):
                self.updateStatus("房间能力切换失败：\(error.localizedDescription)")
            }
        }
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
}

enum DemoTmkResultLogFormatter {
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

private extension OneToOneViewModel {
    func startOnlineListening() {
        TmkTranslationSDK.shared.verifyAuth { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.isAuthVerified = true
                self.updateStatus("鉴权成功，准备创建房间...")
                self.createRoomAndChannel()
            case .failure(let error):
                self.isAuthVerified = false
                self.updateStatus(DemoSDKConfigurationFactory.authFailureMessage(error))
            }
        }
    }

    func createRoomAndChannel() {
        let roomConfig = TmkTranslationRoomConfig(
            sourceLang: selectedRightLang,
            targetLang: selectedLeftLang,
            scenario: selectedScenarioOption.roomScenario,
            channelScenario: .oneToOne,
            speakers: configuredSpeakers(),
            translateEngine: selectedTranslateEngine,
            translateMode: .partial,
            dialogConversationAudioMode: selectedDialogConversationAudioMode
        )
        TmkTranslationSDK.shared.createTmkTranslationRoom(config: roomConfig) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let room):
                self.createTranslationChannel(room: room)
            case .failure(let error):
                self.updateStatus("房间创建失败：\(error.localizedDescription)")
            }
        }
    }

    func createTranslationChannel(room: TmkTranslationRoom) {
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

        TmkTranslationSDK.shared.createTranslationChannel(config) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let channel):
                self.channel = channel
                channel.setTranslationListener(self)
                self.updateStateOnMain { $0.canStartListening = true }
                self.updateStatus("在线通道已就绪，点击“开始收听”开始采集")
            case .failure(let error):
                self.updateStatus("通道启动失败：\(error.localizedDescription)")
            }
        }
    }

    func stopListeningIfNeeded() {
        guard hasStoppedListening == false else { return }
        hasStoppedListening = true
        pendingRowsPublishWorkItem?.cancel()
        pendingRowsPublishWorkItem = nil
        setListeningActive(false)
        voiceIO?.stop()
        closeAllPCMFiles()
        resetLocalPCMPlaybackState()
        voiceIO = nil
        isPCMRecordingEnabled = false
        TmkTranslationSDK.shared.releaseChannel()
        channel = nil
        room = nil
        activePlaybackUID = nil
        targetPlaybackUIDs.removeAll()
        playbackLaneByUID.removeAll()
        updateStatus("已停止收听")
        Self.logger.info("oneToOne channel stopped")
    }

    func recreateRoomAndChannel(statusText: String = "语言已切换，重新创建通道中...") {
        voiceIO?.stop()
        closeAllPCMFiles()
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
            $0.canSharePCM = false
            $0.playbackChannels = 0
            $0.currentRoomNo = "-"
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

    func updateStateOnMain(_ action: @escaping (inout OneToOneViewState) -> Void) {
        DispatchQueue.main.async {
            var newState = self.state
            action(&newState)
            self.state = newState
        }
    }

    func resetRows() {
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
        DispatchQueue.main.async {
            let lane: OneToOneRowViewData.Lane = snapshot.lane == .right ? .right : .left
            let key = self.rowKey(bubbleId: snapshot.bubbleId, lane: lane)
            self.indexSessions(of: snapshot, key: key)
            if let rowIndex = self.rowIndexMap[key], self.rows.indices.contains(rowIndex) {
                var row = self.rows[rowIndex]
                row.sessionId = snapshot.sessionId
                row.sourceLangCode = snapshot.sourceLangCode
                row.targetLangCode = snapshot.targetLangCode
                row.sourceText = snapshot.sourceText
                row.translatedText = snapshot.translatedText
                row.sourceSegments = self.highlightedSource(snapshot.sourceSegments)
                row.translatedSegments = self.highlightedTranslated(snapshot.translatedSegments)
                row.isBubbleEnded = snapshot.isBubbleEnded
                self.rows[rowIndex] = row
                self.rowMutation.send(.update(row: row, index: rowIndex, heightMayChange: true))
            } else {
                let row = OneToOneRowViewData(sessionId: snapshot.sessionId,
                                              bubbleId: snapshot.bubbleId,
                                              lane: lane,
                                              sourceLangCode: snapshot.sourceLangCode,
                                              targetLangCode: snapshot.targetLangCode,
                                              sourceText: snapshot.sourceText,
                                              translatedText: snapshot.translatedText,
                                              sourceSegments: self.highlightedSource(snapshot.sourceSegments),
                                              translatedSegments: self.highlightedTranslated(snapshot.translatedSegments),
                                              isBubbleEnded: snapshot.isBubbleEnded)
                self.rows.append(row)
                let rowIndex = self.rows.count - 1
                self.rowIndexMap[key] = rowIndex
                self.rowMutation.send(.insert(row: row, index: rowIndex))
            }
            self.trimRowsIfNeeded()
            self.schedulePublishRows()
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: workItem)
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
                                     chunkId: event.chunkId)
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

    func preparePCMOutputDirectory() {
        closeAllPCMFiles()
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let outputDir = dir.appendingPathComponent("OneToOneAudio_\(formatter.string(from: Date()))", isDirectory: true)
        try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        pcmOutputDirectory = outputDir
        pcmFileHandles.removeAll()
        pcmFileURLs.removeAll()
        hasPCMData = false
        updateStateOnMain { $0.pcmFileURL = outputDir }
    }

    private func writePCMData(_ data: Data, uid: Int, kind: PCMKind) {
        guard data.isEmpty == false else { return }
        guard let outputDir = pcmOutputDirectory else { return }
        let key = PCMFileKey(uid: uid, kind: kind)
        let handle: FileHandle
        if let existingHandle = pcmFileHandles[key] {
            handle = existingHandle
        } else {
            let fileURL = outputDir.appendingPathComponent("uid_\(uid)_\(kind.rawValue).pcm")
            if FileManager.default.fileExists(atPath: fileURL.path) == false {
                FileManager.default.createFile(atPath: fileURL.path, contents: nil)
            }
            guard let newHandle = try? FileHandle(forWritingTo: fileURL) else { return }
            pcmFileHandles[key] = newHandle
            pcmFileURLs[key] = fileURL
            handle = newHandle
        }
        do {
            try handle.write(contentsOf: data)
            hasPCMData = true
            updateStateOnMain { $0.canSharePCM = true }
        } catch {}
    }

    func closeAllPCMFiles() {
        pcmFileHandles.values.forEach { try? $0.close() }
        pcmFileHandles.removeAll()
    }

    func resetLocalPCMPlaybackState() {
        leftFileAudioLoopBuffer.reset()
    }

    func nextLeftFileAudioChunk(expectedLength: Int) -> OneToOneLocalAudioLoopChunk {
        leftFileAudioLoopBuffer.nextLoopChunk(expectedLength: expectedLength)
    }

    func makeStereoFromMono(_ mono: Data) -> Data {
        guard mono.isEmpty == false else { return Data() }
        var aligned = mono
        if aligned.count.isMultiple(of: 2) == false {
            aligned = Data(aligned.prefix(aligned.count - 1))
        }
        guard aligned.isEmpty == false else { return Data() }
        var stereo = Data(capacity: aligned.count * 2)
        aligned.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            var offset = 0
            while offset + 1 < aligned.count {
                let b0 = base[offset]
                let b1 = base[offset + 1]
                stereo.append(b0)
                stereo.append(b1)
                stereo.append(b0)
                stereo.append(b1)
                offset += 2
            }
        }
        return stereo
    }

    func audioUID(from result: TmkResult<String>) -> Int? {
        let uidValue = result.extraData["uid"]
        if let intValue = uidValue as? Int { return intValue }
        if let uintValue = uidValue as? UInt { return Int(uintValue) }
        if let strValue = uidValue as? String { return Int(strValue) }
        return result.sessionId > 0 ? result.sessionId : nil
    }

    func audioRoute(from result: TmkResult<String>) -> TmkTranslatedAudioRoute? {
        let routeValue = result.extraData["audio_route"]
        if let route = routeValue as? TmkTranslatedAudioRoute { return route }
        if let route = routeValue as? String { return TmkTranslatedAudioRoute(rawValue: route) }
        return nil
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

    func getPlaybackMode() -> OneToOnePlaybackMode {
        stateLock.lock()
        defer { stateLock.unlock() }
        return playbackMode
    }

    func getCaptureEnabled() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return isCaptureEnabled
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
        pendingRowsPublishWorkItem?.cancel()
        pendingRowsPublishWorkItem = nil
        setListeningActive(false)
        voiceIO?.stop()
        closeAllPCMFiles()
        resetLocalPCMPlaybackState()
        voiceIO = nil
        isPCMRecordingEnabled = false
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
            $0.canSharePCM = self.hasPCMData
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
        NSLog("%@", DemoTmkResultLogFormatter.makeLine(scene: "Online1V1", stage: "ASR", result: result, isFinal: isFinal))
        guard let event = DemoConversationEventAdapter.makeRecognizedEvent(from: result, isFinal: isFinal) else { return }
        let normalized = normalizedConversationEvent(from: event, explicitLane: lane(from: result))
        let snapshots = bubbleAssembler.consume(normalized)
        guard snapshots.isEmpty == false else { return }
        snapshots.forEach(applyBubbleSnapshot)
    }

    func onTranslate(from engine: AbstractChannelEngine, result: TmkResult<String>, isFinal: Bool) {
        _ = engine
        NSLog("%@", DemoTmkResultLogFormatter.makeLine(scene: "Online1V1", stage: "MT", result: result, isFinal: isFinal))
        guard let event = DemoConversationEventAdapter.makeTranslatedEvent(from: result, isFinal: isFinal) else { return }
        let normalized = normalizedConversationEvent(from: event, explicitLane: lane(from: result))
        let snapshots = bubbleAssembler.consume(normalized)
        guard snapshots.isEmpty == false else { return }
        snapshots.forEach(applyBubbleSnapshot)
    }

    func onAudioDataReceive(from engine: AbstractChannelEngine, result: TmkResult<String>, data: Data, channelCount: Int) {
        _ = engine
        guard result.data == "translated_audio", data.isEmpty == false else { return }
        audioProcessQueue.async { [weak self] in
            autoreleasepool {
                guard let self else { return }
                guard self.getListeningActive() else { return }
                self.updatePlaybackChannel(channelCount)
                let uid = self.audioUID(from: result)
                let audioRoute = self.audioRoute(from: result)
                let stereoData: Data
                let leftData: Data
                let rightData: Data
                if audioRoute == .left || audioRoute == .right {
                    stereoData = Data()
                    leftData = data
                    rightData = data
                } else if channelCount >= 2, let split = TmkTranslationPCMTools.splitStereoInterleaved16LE(data) {
                    stereoData = data
                    leftData = split.left
                    rightData = split.right
                } else {
                    leftData = data
                    rightData = data
                    stereoData = self.makeStereoFromMono(data)
                }
                let lane: OneToOneRowViewData.Lane?
                switch audioRoute {
                case .left:
                    lane = .left
                case .right:
                    lane = .right
                case .stereo:
                    lane = nil
                case .none:
                    lane = uid.flatMap { self.playbackLaneByUID[$0] }
                }
                if self.isPCMRecordingEnabled {
                    if self.pcmOutputDirectory == nil {
                        self.preparePCMOutputDirectory()
                    }
                    let fileUID = uid ?? Int(self.room?.channelDialogResponse?.roomNo ?? "0") ?? 0
                    if audioRoute == .stereo {
                        self.writePCMData(stereoData, uid: fileUID, kind: .stereo)
                        self.writePCMData(leftData, uid: fileUID, kind: .left)
                        self.writePCMData(rightData, uid: fileUID, kind: .right)
                    } else if let lane {
                        self.writePCMData(data, uid: fileUID, kind: lane == .left ? .left : .right)
                    } else {
                        self.writePCMData(stereoData, uid: fileUID, kind: .stereo)
                        self.writePCMData(leftData, uid: fileUID, kind: .left)
                        self.writePCMData(rightData, uid: fileUID, kind: .right)
                    }
                }
                let playbackMode = self.getPlaybackMode()
                let sourceLane = lane ?? (playbackMode == .left ? OneToOneRowViewData.Lane.left : .right)
                guard let output = OneToOneTranslatedAudioPlaybackSelector.selectPlaybackData(
                    data: data,
                    channelCount: channelCount,
                    playbackMode: playbackMode,
                    audioRoute: audioRoute,
                    sourceLane: sourceLane,
                    extraData: result.extraData
                ) else { return }
                self.voiceIO?.enqueuePlaybackPCM(output)
            }
        }
    }

    func onError(_ error: TmkTranslationError) {
        applyRuntimeAction(DemoConversationRuntimePolicy.action(for: error))
    }

    func onEvent(name: String, args: Any?) {
        if DemoConversationRuntimePolicy.isCloseRoomEvent(name: name, args: args) {
            handleRemoteCloseRoom()
            return
        }
        let networkAction = networkEventPolicy.action(forEvent: name, args: args)
        if networkAction != .none {
            applyRuntimeAction(networkAction)
            return
        }
        if name == "online_bubble_end",
           let result = args as? TmkResult<String> {
            let snapshots = bubbleAssembler.markBubbleEnded(bubbleId: result.bubbleId)
            NSLog("%@", DemoTmkResultLogFormatter.makeBubbleEndLine(scene: "Online1V1",
                                                                     result: result,
                                                                     affectedSnapshots: snapshots))
            snapshots.forEach(applyBubbleSnapshot)
            return
        }
        if name == "online_tts_state",
           let result = args as? TmkResult<String> {
            NSLog("%@", DemoTmkResultLogFormatter.makeLine(scene: "Online1V1",
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
        applyRuntimeAction(DemoConversationRuntimePolicy.action(for: snapshot))
    }

    private func handleRemoteCloseRoom() {
        guard hasStoppedListening == false else { return }
        hasStoppedListening = true
        pendingRowsPublishWorkItem?.cancel()
        pendingRowsPublishWorkItem = nil
        setListeningActive(false)
        voiceIO?.stop()
        closeAllPCMFiles()
        resetLocalPCMPlaybackState()
        voiceIO = nil
        isPCMRecordingEnabled = false
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
            $0.canSharePCM = self.hasPCMData
            $0.currentRoomNo = "-"
            $0.captureSampleRate = 0
            $0.captureChannels = 0
            $0.playbackChannels = 0
        }
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
