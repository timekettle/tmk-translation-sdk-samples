import Foundation
import Combine
import OSLog
import TmkTranslationSDK
import AVFoundation

final class NowListeningViewModel: NSObject {
    private static let logger = Logger(subsystem: "co.timekettle.demo", category: "NowListening")
    @Published private(set) var state = NowListeningViewState()
    let rowMutation = PassthroughSubject<ChatListMutation<NowListeningRowViewData>, Never>()
    let remoteCloseRoomPrompt = PassthroughSubject<DemoConversationPrompt, Never>()

    private var room: TmkTranslationRoom?
    private var channel: TmkTranslationChannel?
    private var voiceIO: TmkVoiceProcessingIO?
    private var hasStoppedListening = false

    private var rows: [NowListeningRowViewData] = []
    private var bubbleIndexMap: [String: Int] = [:]
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
    private var lastPublishedRows: [NowListeningRowViewData] = []
    private var targetPlaybackUIDs: Set<Int> = []
    private var activePlaybackUID: Int?
    private var selectedSourceLang = "zh-CN"
    private var selectedTargetLang = "en-US"
    private var selectedSpeakerGender: TmkSpeakerGender = .female
    private var selectedTranslateEngine: TmkOnlineTranslateEngine = .accurate
    private var selectedScenarioOption: NowListeningScenarioOption = .defaultOption
    private var supportedLanguages: Set<String> = []
    private var isAuthVerified = false

    private let audioProcessQueue = DispatchQueue(label: "co.timekettle.demo.nowlistening.audio")
    private let stateLock = NSLock()
    private var isListeningActive = false
    private var isCaptureEnabled = false
    private var cachedCaptureSampleRate: Int = -1
    private var cachedCaptureChannels: Int = -1
    private var cachedPlaybackChannels: Int = -1
    private let maxDisplayedRows = 200

    private var pcmFileHandle: FileHandle?
    private var hasPCMData = false
    private var isPCMRecordingEnabled = false
    private let networkEventPolicy = DemoOnlineNetworkEventPolicy()

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
            $0.scenarioOption = self.selectedScenarioOption
            $0.isCaptureEnabled = self.isCaptureEnabled
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
        let tapAt = Date()
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
            Self.logger.info("startListening durationMs=\(self.durationMs(since: tapAt), privacy: .public) result=failure(audio_session)")
            return
        }

        voiceIO.onInputPCM = { [weak self, weak channel] data, format, _ in
            guard let self else { return }
            let captureChannels = Int(format.mChannelsPerFrame)
            self.updateCaptureAudioInfo(sampleRate: Int(format.mSampleRate), channels: captureChannels)
            channel?.pushStreamAudioData(data, channelCount: captureChannels, extraChunk: nil)
        }

        voiceIO.requestRecordPermission { [weak self] granted in
            guard let self else { return }
            Self.logger.info("startListening permissionDurationMs=\(self.durationMs(since: tapAt), privacy: .public) granted=\(granted, privacy: .public)")
            guard granted else {
                self.updateStatus("麦克风权限未授权")
                return
            }
            let ioStartAt = Date()
            do {
                if self.isPCMRecordingEnabled {
                    self.preparePCMFileForWriting()
                }
                try voiceIO.start()
                self.setListeningActive(true)
                self.updateStateOnMain {
                    $0.canStopListening = true
                    $0.canStartListening = false
                    $0.canSharePCM = false
                }
                self.updateStatus("正在收听中...")
                Self.logger.info("startListening ioStartDurationMs=\(self.durationMs(since: ioStartAt), privacy: .public) result=success")
            } catch {
                self.updateStatus("开始收听失败：\(error.localizedDescription)")
                Self.logger.info("startListening ioStartDurationMs=\(self.durationMs(since: ioStartAt), privacy: .public) result=failure(start_io)")
            }
        }
    }

    func stopListening() {
        voiceIO?.stop()
        closePCMFile()
        setListeningActive(false)
        activePlaybackUID = nil
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

    var currentPCMURL: URL? {
        state.pcmFileURL
    }

    @discardableResult
    func enablePCMRecordingIfNeeded() -> Bool {
        if isPCMRecordingEnabled { return false }
        isPCMRecordingEnabled = true
        if getListeningActive(), pcmFileHandle == nil {
            preparePCMFileForWriting()
        }
        updateStatus("已开启PCM录制，请先进行对话后再分享")
        return true
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

    func applyLanguages(source: String, target: String) {
        guard source != target else {
            updateStatus("源语言和目标语言不能相同")
            return
        }
        guard supportedLanguages.contains(source), supportedLanguages.contains(target) else {
            updateStatus("语言不在支持列表中")
            return
        }
        guard source != selectedSourceLang || target != selectedTargetLang else { return }
        updateListeningLanguages(source: source, target: target)
    }

    func setCaptureEnabled(_ enabled: Bool) {
        stateLock.lock()
        isCaptureEnabled = enabled
        stateLock.unlock()
        isPCMRecordingEnabled = enabled
        if enabled, getListeningActive(), pcmFileHandle == nil {
            preparePCMFileForWriting()
        }
        if enabled == false {
            closePCMFile()
        }
        updateStateOnMain { $0.isCaptureEnabled = enabled }
    }

    func updateSpeaker(gender: TmkSpeakerGender) {
        selectedSpeakerGender = gender
        let speaker = TmkSpeaker(channel: .left, gender: gender)
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

    func updateScenarioOption(_ option: NowListeningScenarioOption) {
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
}

private extension NowListeningViewModel {
    func startOnlineListening() {
        let startupStartedAt = Date()
        let authStartedAt = Date()
        TmkTranslationSDK.shared.verifyAuth { [weak self] result in
            guard let self else { return }
            let authDurationMs = self.durationMs(since: authStartedAt)
            switch result {
            case .success:
                self.isAuthVerified = true
                Self.logger.info("启动翻译耗时 鉴权耗时 authDurationMs=\(authDurationMs, privacy: .public) result=success")
                self.updateStatus("鉴权成功，准备创建房间...")
                self.createRoomAndChannel(startupStartedAt: startupStartedAt)
            case .failure(let error):
                self.isAuthVerified = false
                Self.logger.info("启动翻译耗时 鉴权耗时 authDurationMs=\(authDurationMs, privacy: .public) totalDurationMs=\(self.durationMs(since: startupStartedAt), privacy: .public) result=failure")
                self.updateStatus(DemoSDKConfigurationFactory.authFailureMessage(error))
            }
        }
    }

    func createRoomAndChannel(startupStartedAt: Date) {
        let roomStartedAt = Date()
        let settings = DemoSettingsStore().loadCurrentConfig()
        let roomConfig = TmkTranslationRoomConfig(
            sourceLang: selectedSourceLang,
            targetLang: selectedTargetLang,
            scenario: selectedScenarioOption.roomScenario,
            channelScenario: .listen,
            speakers: configuredSpeakers(),
            translateEngine: selectedTranslateEngine,
            enableSensitiveWordRedaction: settings.sensitiveWordRedactionEnabled ? .enabled : .disabled
        )
        TmkTranslationSDK.shared.createTmkTranslationRoom(config: roomConfig) { [weak self] roomResult in
            guard let self else { return }
            let roomDurationMs = self.durationMs(since: roomStartedAt)
            switch roomResult {
            case .success(let room):
                Self.logger.info("启动翻译耗时 创建房间耗时 roomDurationMs=\(roomDurationMs, privacy: .public) result=success")
                self.createTranslationChannel(room: room, startupStartedAt: startupStartedAt)
            case .failure(let error):
                Self.logger.info("启动翻译耗时 创建房间耗时 roomDurationMs=\(roomDurationMs, privacy: .public) totalDurationMs=\(self.durationMs(since: startupStartedAt), privacy: .public) result=failure")
                self.updateStatus("房间创建失败：\(error.localizedDescription)")
            }
        }
    }

    func createTranslationChannel(room: TmkTranslationRoom, startupStartedAt: Date) {
        self.room = room
        refreshTargetPlaybackUIDs(from: room)

        let channelConfig = TmkTranslationChannelConfig.Builder()
            .setRoom(room)
            .setScenario(.listen)
            .setMode(.online)
            .setSourceLang(selectedSourceLang)
            .setTargetLang(selectedTargetLang)
            .setSpeakers(configuredSpeakers())
            .setPCMSampleRate(16_000)
            .setPCMChannels(1)
            .build()

        updateStateOnMain {
            $0.currentRoomNo = room.channelDialogResponse?.roomNo ?? "-"
            $0.configuredSampleRate = channelConfig.pcmSampleRate
            $0.configuredChannels = channelConfig.pcmChannels
        }

        let channelStartedAt = Date()
        TmkTranslationSDK.shared.createTranslationChannel(channelConfig, listener: self) { [weak self] channelResult in
            guard let self else { return }
            let channelDurationMs = self.durationMs(since: channelStartedAt)
            let totalDurationMs = self.durationMs(since: startupStartedAt)
            switch channelResult {
            case .success(let channel):
                self.channel = channel
                self.updateStateOnMain {
                    $0.canStartListening = true
                }
                Self.logger.info("启动翻译耗时 加入通道耗时 channelDurationMs=\(channelDurationMs, privacy: .public) totalDurationMs=\(totalDurationMs, privacy: .public) result=success")
                self.updateStatus("在线通道已就绪，点击“开始收听”开始采集")
            case .failure(let error):
                Self.logger.info("启动翻译耗时 加入通道耗时 channelDurationMs=\(channelDurationMs, privacy: .public) totalDurationMs=\(totalDurationMs, privacy: .public) result=failure")
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
        closePCMFile()
        voiceIO = nil
        isPCMRecordingEnabled = false
        TmkTranslationSDK.shared.releaseChannel()
        channel = nil
        room = nil
        activePlaybackUID = nil
        updateStatus("已停止收听")
        Self.logger.info("channel stopped")
    }

    func recreateRoomAndChannel(statusText: String) {
        voiceIO?.stop()
        closePCMFile()
        setListeningActive(false)
        voiceIO = nil
        isPCMRecordingEnabled = false
        TmkTranslationSDK.shared.releaseChannel()
        channel = nil
        room = nil
        activePlaybackUID = nil
        targetPlaybackUIDs.removeAll()
        cachedCaptureSampleRate = -1
        cachedCaptureChannels = -1
        cachedPlaybackChannels = -1
        hasStoppedListening = false
        resetRows()
        updateStateOnMain {
            $0.rows = []
            $0.canStartListening = false
            $0.canStopListening = false
            $0.canSharePCM = false
            $0.currentRoomNo = "-"
            $0.captureSampleRate = 0
            $0.captureChannels = 0
            $0.playbackChannels = 0
        }
        updateStatus(statusText)
        startOnlineListening()
    }

    func updateListeningLanguages(source: String, target: String) {
        guard let room else {
            selectedSourceLang = source
            selectedTargetLang = target
            activePlaybackUID = nil
            targetPlaybackUIDs.removeAll()
            cachedPlaybackChannels = -1
            updateStateOnMain {
                $0.playbackChannels = 0
                $0.sourceLanguage = source
                $0.targetLanguage = target
            }
            updateStatus("语言已切换，将在下次创建房间后生效")
            return
        }
        updateStatus("语言已切换，正在更新房间语言，下一句话生效...")
        _ = updateListeningRoomLocale(room: room,
                                      sourceLang: source,
                                      targetLang: target) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.selectedSourceLang = source
                self.selectedTargetLang = target
                self.activePlaybackUID = nil
                self.targetPlaybackUIDs.removeAll()
                self.cachedPlaybackChannels = -1
                self.updateStateOnMain {
                    $0.playbackChannels = 0
                    $0.sourceLanguage = source
                    $0.targetLanguage = target
                }
                self.channel?.updateLanguages(sourceLang: source,
                                              targetLang: target)
                self.updateStatus("房间语言已更新，下一句话生效")
            case .failure(let error):
                self.updateStatus("更新房间语言失败：\(error.localizedDescription)")
            }
        }
    }

    @discardableResult
    private func updateListeningRoomLocale(room: TmkTranslationRoom,
                                           sourceLang: String,
                                           targetLang: String,
                                           completion: @escaping (Result<Void, TmkTranslationError>) -> Void) -> TmkSDKCancellable? {
        room.updateRoomLocale(sourceLocales: [sourceLang],
                              targetLocales: [targetLang],
                              completion: completion)
    }

    func updateStatus(_ text: String) {
        updateStateOnMain { $0.statusText = text }
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

    func updateStateOnMain(_ action: @escaping (inout NowListeningViewState) -> Void) {
        DispatchQueue.main.async {
            var newState = self.state
            action(&newState)
            self.state = newState
        }
    }

    func resetRows() {
        rows.removeAll()
        bubbleIndexMap.removeAll()
        rawSessionRowKey.removeAll()
        rawChunkRowKey.removeAll()
        blueSessions.removeAll()
        blueChunks.removeAll()
        bubbleAssembler.reset()
        lastPublishedRows = []
        pendingRowsPublishWorkItem?.cancel()
        pendingRowsPublishWorkItem = nil
        rowMutation.send(.reset(rows: []))
    }

    func applyBubbleSnapshot(_ snapshot: DemoConversationBubbleSnapshot) {
        DispatchQueue.main.async {
            let key = DemoConversationBubbleAssembler.rowKey(bubbleId: snapshot.bubbleId, lane: .left)
            self.indexSessions(of: snapshot, key: key)
            if let rowIndex = self.bubbleIndexMap[key], self.rows.indices.contains(rowIndex) {
                var row = self.rows[rowIndex]
                row.sessionId = snapshot.sessionId
                row.sourceLangCode = snapshot.sourceLangCode
                row.targetLangCode = snapshot.targetLangCode
                row.sourceText = snapshot.sourceText
                row.translatedText = snapshot.translatedText
                row.sourceSegments = self.highlightedSource(snapshot.sourceSegments)
                row.translatedSegments = self.highlightedTranslated(snapshot.translatedSegments)
                row.isBubbleEnded = snapshot.isBubbleEnded
                row.bOffset = snapshot.bOffset
                row.bDuration = snapshot.bDuration
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
                                              translatedText: snapshot.translatedText,
                                              sourceSegments: self.highlightedSource(snapshot.sourceSegments),
                                              translatedSegments: self.highlightedTranslated(snapshot.translatedSegments),
                                              isBubbleEnded: snapshot.isBubbleEnded,
                                              bOffset: snapshot.bOffset,
                                              bDuration: snapshot.bDuration)
            self.rows.append(row)
            let newIndex = self.rows.count - 1
            self.bubbleIndexMap[key] = newIndex
            self.rowMutation.send(.insert(row: row, index: newIndex))
            self.trimRowsIfNeeded()
            self.publishRows()
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
                guard let idx = self.bubbleIndexMap[key], self.rows.indices.contains(idx) else { continue }
                var row = self.rows[idx]
                row.sourceSegments = self.highlightedSource(row.sourceSegments)
                row.translatedSegments = self.highlightedTranslated(row.translatedSegments)
                guard row != self.rows[idx] else { continue }
                self.rows[idx] = row
                self.rowMutation.send(.update(row: row, index: idx, heightMayChange: false))
            }
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
        // 收敛 session/chunk 相关字典/集合到当前仍存在的行，避免无限增长。
        let liveSegments = rows.flatMap { $0.sourceSegments + $0.translatedSegments }
        let liveSessions = Set(liveSegments.flatMap { $0.rawSessionIds })
        let liveChunks = Set(liveSegments.flatMap { $0.rawChunkIds })
        rawSessionRowKey = rawSessionRowKey.filter { liveSessions.contains($0.key) }
        rawChunkRowKey = rawChunkRowKey.filter { liveChunks.contains($0.key) }
        blueSessions.formIntersection(liveSessions)
        blueChunks.formIntersection(liveChunks)
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

    func refreshTargetPlaybackUIDs(from room: TmkTranslationRoom) {
        guard let dialog = room.channelDialogResponse else {
            targetPlaybackUIDs = []
            return
        }
        let targetPrefix = selectedTargetLang.lowercased()
        let preferred = dialog.translationList
            .filter { item in
                let locale = item.locale.lowercased()
                return locale.hasPrefix(targetPrefix) || targetPrefix.hasPrefix(locale)
            }
            .compactMap { Int($0.subscribeUid) }
        if preferred.isEmpty == false {
            targetPlaybackUIDs = Set(preferred)
            activePlaybackUID = preferred.first
            return
        }
        let fallback = dialog.translationList.compactMap { Int($0.subscribeUid) }
        targetPlaybackUIDs = Set(fallback)
        activePlaybackUID = fallback.first
    }

    func configuredSpeakers() -> [TmkSpeaker] {
        [TmkSpeaker(channel: .left, gender: selectedSpeakerGender)]
    }

    func durationMs(since startAt: Date) -> Int {
        Int(Date().timeIntervalSince(startAt) * 1000)
    }

    func preparePCMFileForWriting() {
        closePCMFile()
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let filename = "NowListening_\(formatter.string(from: Date())).pcm"
        let url = dir.appendingPathComponent(filename)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        hasPCMData = false
        do {
            pcmFileHandle = try FileHandle(forWritingTo: url)
            updateStateOnMain { $0.pcmFileURL = url }
        } catch {
            pcmFileHandle = nil
            updateStateOnMain { $0.pcmFileURL = nil }
            updateStatus("PCM文件创建失败：\(error.localizedDescription)")
        }
    }

    func writePCMDataToFile(_ data: Data) {
        guard data.isEmpty == false else { return }
        guard let handle = pcmFileHandle else { return }
        do {
            try handle.write(contentsOf: data)
            hasPCMData = true
        } catch {
            updateStatus("PCM写入失败：\(error.localizedDescription)")
        }
    }

    func closePCMFile() {
        try? pcmFileHandle?.close()
        pcmFileHandle = nil
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
        closePCMFile()
        voiceIO = nil
        isPCMRecordingEnabled = false
        TmkTranslationSDK.shared.releaseChannel()
        channel = nil
        room = nil
        activePlaybackUID = nil
        targetPlaybackUIDs.removeAll()
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

enum NowListeningConversationEventNormalizer {
    /// 在线收听只有单侧展示，归一化时只固定 lane，不改变服务端返回的 bubble/session/chunk 关系。
    static func normalized(_ event: DemoConversationEvent) -> DemoConversationEvent {
        DemoConversationEvent(bubbleId: event.bubbleId,
                              sessionId: event.sessionId,
                              lane: .left,
                              stage: event.stage,
                              isFinal: event.isFinal,
                              text: event.text,
                              sourceLangCode: event.sourceLangCode,
                              targetLangCode: event.targetLangCode,
                              chunkId: event.chunkId,
                              offset: event.offset,
                              duration: event.duration)
    }
}

extension NowListeningViewModel: TmkTranslationListener {
    func onRecognized(from engine: AbstractChannelEngine, result: TmkResult<String>, isFinal: Bool) {
        _ = engine
        DemoTmkResultLogFormatter.log(DemoTmkResultLogFormatter.makeLine(scene: "OnlineListen", stage: "ASR", result: result, isFinal: isFinal))
        guard let event = DemoConversationEventAdapter.makeRecognizedEvent(from: result, isFinal: isFinal) else { return }
        let normalized = NowListeningConversationEventNormalizer.normalized(event)
        let snapshots = bubbleAssembler.consume(normalized)
        guard snapshots.isEmpty == false else { return }
        snapshots.forEach(applyBubbleSnapshot)
    }

    func onTranslate(from engine: AbstractChannelEngine, result: TmkResult<String>, isFinal: Bool) {
        _ = engine
        DemoTmkResultLogFormatter.log(DemoTmkResultLogFormatter.makeLine(scene: "OnlineListen", stage: "MT", result: result, isFinal: isFinal))
        guard let event = DemoConversationEventAdapter.makeTranslatedEvent(from: result, isFinal: isFinal) else { return }
        let normalized = NowListeningConversationEventNormalizer.normalized(event)
        let snapshots = bubbleAssembler.consume(normalized)
        guard snapshots.isEmpty == false else { return }
        snapshots.forEach(applyBubbleSnapshot)
    }

    func onAudioDataReceive(from engine: AbstractChannelEngine, result: TmkResult<String>, data: Data, channelCount: Int) {
        _ = engine
        guard result.data == "translated_audio" else { return }
        audioProcessQueue.async { [weak self] in
            autoreleasepool {
                guard let self else { return }
                guard self.getListeningActive() else { return }
                self.updatePlaybackChannel(channelCount)
                
                if result.dstCode.lowercased().hasPrefix(self.selectedTargetLang.lowercased()) == false { return }
                
//                let uidValue = result.extraData["uid"]
//                let uid: Int? = {
//                    if let intValue = uidValue as? Int { return intValue }
//                    if let uintValue = uidValue as? UInt { return Int(uintValue) }
//                    if let strValue = uidValue as? String { return Int(strValue) }
//                    return nil
//                }()
//                guard let uid else { return }
//                if self.targetPlaybackUIDs.isEmpty { self.targetPlaybackUIDs.insert(uid) }
//                guard self.targetPlaybackUIDs.contains(uid) else { return }
//                if self.activePlaybackUID == nil { self.activePlaybackUID = uid }
//                guard self.activePlaybackUID == uid else { return }
                
                if self.isPCMRecordingEnabled {
                    if self.pcmFileHandle == nil {
                        self.preparePCMFileForWriting()
                    }
                    self.writePCMDataToFile(data)
                }
                self.voiceIO?.enqueuePlaybackPCM(data)
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
            DemoTmkResultLogFormatter.log(DemoTmkResultLogFormatter.makeBubbleEndLine(scene: "OnlineListen",
                                                                     result: result,
                                                                     affectedSnapshots: snapshots))
            snapshots.forEach(applyBubbleSnapshot)
            return
        }
        if name == "online_tts_state",
           let result = args as? TmkResult<String> {
            DemoTmkResultLogFormatter.log(DemoTmkResultLogFormatter.makeLine(scene: "OnlineListen",
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
        applyRuntimeAction(DemoConversationRuntimePolicy.action(for: snapshot,
                                                                isListening: getListeningActive()))
    }

    private func handleRemoteCloseRoom() {
        guard hasStoppedListening == false else { return }
        hasStoppedListening = true
        pendingRowsPublishWorkItem?.cancel()
        pendingRowsPublishWorkItem = nil
        setListeningActive(false)
        voiceIO?.stop()
        closePCMFile()
        voiceIO = nil
        isPCMRecordingEnabled = false
        TmkTranslationSDK.shared.releaseChannel()
        channel = nil
        room = nil
        activePlaybackUID = nil
        targetPlaybackUIDs.removeAll()
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
        Self.logger.info("nowListening remote close_room received, waiting for user decision")
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
