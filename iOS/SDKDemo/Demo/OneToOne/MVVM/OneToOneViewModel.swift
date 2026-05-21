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
    private let bubbleAssembler = DemoConversationBubbleAssembler()
    private var pendingRowsPublishWorkItem: DispatchWorkItem?
    private var lastPublishedRows: [OneToOneRowViewData] = []

    private var targetPlaybackUIDs: Set<Int> = []
    private var activePlaybackUID: Int?
    private var selectedSourceLang = "zh-CN"
    private var selectedTargetLang = "en-US"
    private var selectedLeftSpeakerGender: TmkSpeakerGender = .male
    private var selectedRightSpeakerGender: TmkSpeakerGender = .female
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
    private var localPCMOffset: Int = 0
    private var localPCMLoopResumeAt: CFAbsoluteTime?
    private let localAudioLoopRestartDelay: TimeInterval = 2
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

        do {
            try TmkVoiceProcessingIO.configureAudioSession(sampleRate: 16000,
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
            self.updateCaptureAudioInfo(sampleRate: micSampleRate, channels: 2)
            _ = micChannels
            // VoiceProcessingIO 采集配置为单声道，直接使用输入数据作为左声道。
            //右边推的源语言，则SDK返回的音频中，源语言的翻译结果会在右声道返回。
            let recordData = data.count.isMultiple(of: 2) ? data : Data(data.prefix(data.count - 1))
            guard recordData.isEmpty == false else { return }
            let fileData = self.nextRightAudioChunk(expectedLength: recordData.count)
            let mixed = TmkTranslationPCMTools.mixStereo16LE(left:fileData, right: recordData) ?? Data()
            guard mixed.isEmpty == false else { return }
            channel?.pushStreamAudioData(mixed, channelCount: 2, extraChunk: nil)
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
        updateStateOnMain {
            $0.canStopListening = false
            $0.canStartListening = self.channel != nil
            $0.canSharePCM = self.hasPCMData
        }
        updateStatus("收听已停止")
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
        updateStateOnMain { $0.playbackMode = mode }
    }

    func fetchSupportedLanguages(
        _ completion: @escaping (Result<TmkSupportedLanguagesResponse, TmkTranslationError>) -> Void
    ) {
        _ = TmkTranslationSDK.shared.getSupportedLanguages(source: .online) { [weak self] result in
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
        room = TmkTranslationSDK.shared.createTmkTranslationRoom(sourceLang: selectedSourceLang,
                                                                 targetLang: selectedTargetLang,
                                                                 scenario: .toSpeech,
                                                                 channelScenario: .oneToOne,
                                                                 speakers: configuredSpeakers()) { [weak self] result in
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
            .setSourceLang(selectedSourceLang)
            .setTargetLang(selectedTargetLang)
            .setSpeakers(configuredSpeakers())
            .setPCMSampleRate(16_000)
            .setPCMChannels(2)
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
        let closingRoom = room
        pendingRowsPublishWorkItem?.cancel()
        pendingRowsPublishWorkItem = nil
        setListeningActive(false)
        voiceIO?.stop()
        closeAllPCMFiles()
        resetLocalPCMPlaybackState()
        voiceIO = nil
        isPCMRecordingEnabled = false
        channel?.stop()
        channel = nil
        room = nil
        activePlaybackUID = nil
        updateStatus("已停止收听")
        Self.logger.info("oneToOne channel stopped")
        closeRoomIfNeeded(closingRoom)
    }

    func recreateRoomAndChannel() {
        let closingRoom = room
        voiceIO?.stop()
        closeAllPCMFiles()
        resetLocalPCMPlaybackState()
        setListeningActive(false)
        activePlaybackUID = nil
        targetPlaybackUIDs.removeAll()
        channel?.stop()
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
        updateStatus("语言已切换，重新创建通道中...")
        closeRoomIfNeeded(closingRoom)
        startOnlineListening()
    }

    func updateOneToOneLanguage(source: String) {
        guard let room else {
            selectedSourceLang = source
            activePlaybackUID = nil
            targetPlaybackUIDs.removeAll()
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
            if let rowIndex = self.rowIndexMap[key], self.rows.indices.contains(rowIndex) {
                var row = self.rows[rowIndex]
                row.sessionId = snapshot.sessionId
                row.sourceLangCode = snapshot.sourceLangCode
                row.targetLangCode = snapshot.targetLangCode
                row.sourceText = snapshot.sourceText
                row.translatedText = snapshot.translatedText
                self.rows[rowIndex] = row
                self.rowMutation.send(.update(row: row, index: rowIndex, heightMayChange: true))
            } else {
                let row = OneToOneRowViewData(sessionId: snapshot.sessionId,
                                              bubbleId: snapshot.bubbleId,
                                              lane: lane,
                                              sourceLangCode: snapshot.sourceLangCode,
                                              targetLangCode: snapshot.targetLangCode,
                                              sourceText: snapshot.sourceText,
                                              translatedText: snapshot.translatedText)
                self.rows.append(row)
                let rowIndex = self.rows.count - 1
                self.rowIndexMap[key] = rowIndex
                self.rowMutation.send(.insert(row: row, index: rowIndex))
            }
            self.trimRowsIfNeeded()
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
                                     targetLangCode: languagePair.target)
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
        localPCMOffset = 0
        localPCMLoopResumeAt = nil
    }

    func nextRightAudioChunk(expectedLength: Int) -> Data {
        guard expectedLength > 0 else { return Data() }
        guard let localPCM = localPCMData, localPCM.isEmpty == false else {
            return Data(repeating: 0, count: expectedLength)
        }
        if let resumeAt = localPCMLoopResumeAt {
            let now = CFAbsoluteTimeGetCurrent()
            if now < resumeAt {
                return Data(repeating: 0, count: expectedLength)
            }
            localPCMLoopResumeAt = nil
            localPCMOffset = 0
        }
        var leftSlice = Data(capacity: expectedLength)
        var remain = expectedLength
        while remain > 0 {
            guard localPCMOffset < localPCM.count else {
                localPCMLoopResumeAt = CFAbsoluteTimeGetCurrent() + localAudioLoopRestartDelay
                break
            }
            let available = min(remain, localPCM.count - localPCMOffset)
            guard available > 0 else { break }
            leftSlice.append(localPCM.subdata(in: localPCMOffset..<(localPCMOffset + available)))
            localPCMOffset += available
            remain -= available
            if localPCMOffset >= localPCM.count {
                localPCMLoopResumeAt = CFAbsoluteTimeGetCurrent() + localAudioLoopRestartDelay
                break
            }
        }
        if leftSlice.count < expectedLength {
            leftSlice.append(Data(repeating: 0, count: expectedLength - leftSlice.count))
        }
        return leftSlice
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


    func closeRoomIfNeeded(_ room: TmkTranslationRoom?) {
        guard let room else { return }
        _ = room.closeRoom { result in
            switch result {
            case .success:
                Self.logger.info("oneToOne close room success")
            case .failure(let error):
                Self.logger.error("oneToOne close room failed: \(error.localizedDescription, privacy: .public)")
            }
        }
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
            stopConversationForPrompt(status: prompt.title, closeRoom: true)
            DispatchQueue.main.async { [weak self] in
                self?.remoteCloseRoomPrompt.send(prompt)
            }
        }
    }

    func stopConversationForPrompt(status: String, closeRoom: Bool) {
        guard hasStoppedListening == false else {
            updateStatus(status)
            return
        }
        hasStoppedListening = true
        let closingRoom = closeRoom ? room : nil
        pendingRowsPublishWorkItem?.cancel()
        pendingRowsPublishWorkItem = nil
        setListeningActive(false)
        voiceIO?.stop()
        closeAllPCMFiles()
        resetLocalPCMPlaybackState()
        voiceIO = nil
        isPCMRecordingEnabled = false
        channel?.stop()
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
        closeRoomIfNeeded(closingRoom)
    }
}

extension OneToOneViewModel: TmkTranslationListener {
    func onRecognized(from engine: AbstractChannelEngine, result: TmkResult<String>, isFinal: Bool) {
        _ = engine
        guard let event = DemoConversationEventAdapter.makeRecognizedEvent(from: result, isFinal: isFinal) else { return }
        let normalized = normalizedConversationEvent(from: event, explicitLane: lane(from: result))
        let snapshots = bubbleAssembler.consume(normalized)
        guard snapshots.isEmpty == false else { return }
        snapshots.forEach(applyBubbleSnapshot)
    }

    func onTranslate(from engine: AbstractChannelEngine, result: TmkResult<String>, isFinal: Bool) {
        _ = engine
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
//                let uidValue = result.extraData["uid"]
//                let uid: Int? = {
//                    if let intValue = uidValue as? Int { return intValue }
//                    if let uintValue = uidValue as? UInt { return Int(uintValue) }
//                    if let strValue = uidValue as? String { return Int(strValue) }
//                    return nil
//                }()
//                
//                guard uid != nil else { return }
                let stereoData: Data
                let leftData: Data
                let rightData: Data
                if channelCount >= 2, let split = TmkTranslationPCMTools.splitStereoInterleaved16LE(data) {
                    stereoData = data
                    leftData = split.left
                    rightData = split.right
                } else {
                    leftData = data
                    rightData = data
                    stereoData = self.makeStereoFromMono(data)
                }
                if self.isPCMRecordingEnabled {
                    if self.pcmOutputDirectory == nil {
                        self.preparePCMOutputDirectory()
                    }
                    let roomID = Int(self.room?.channelDialogResponse?.roomNo ?? "0") ?? 0
                    self.writePCMData(stereoData, uid: roomID, kind: .stereo)
                    self.writePCMData(leftData, uid: roomID, kind: .left)
                    self.writePCMData(rightData, uid: roomID, kind: .right)
                }
                let output: Data
                switch self.getPlaybackMode() {
                case .left:
                    output = leftData
                case .right:
                    output = rightData
                }
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
        channel?.stop()
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
