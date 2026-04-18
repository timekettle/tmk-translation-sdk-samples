import Foundation
import Combine
import AVFAudio
import CoreAudioTypes
import OSLog
import TmkTranslationSDK

final class NowListeningViewModel: NSObject {
    private static let logger = Logger(subsystem: "co.timekettle.demo", category: "NowListening")
    @Published private(set) var state = NowListeningViewState()
    let rowMutation = PassthroughSubject<ChatListMutation<NowListeningRowViewData>, Never>()

    private var room: TmkTranslationRoom?
    private var channel: TmkTranslationChannel?
    private var voiceIO: TmkVoiceProcessingIO?
    private var hasStoppedListening = false

    private var rows: [NowListeningRowViewData] = []
    private var bubbleIndexMap: [String: Int] = [:]
    private let bubbleAssembler = DemoConversationBubbleAssembler()
    private var pendingRowsPublishWorkItem: DispatchWorkItem?
    private var lastPublishedRows: [NowListeningRowViewData] = []
    private var targetPlaybackUIDs: Set<Int> = []
    private var activePlaybackUID: Int?
    private var selectedSourceLang = "zh-CN"
    private var selectedTargetLang = "en-US"
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
    private let lingCastAspect = DemoLingCastAspect()

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
        lingCastAspect.setTraceReportingEnabled(false)
        updateStateOnMain {
            $0.sourceLanguage = self.selectedSourceLang
            $0.targetLanguage = self.selectedTargetLang
            $0.isCaptureEnabled = self.isCaptureEnabled
        }
        startOnlineListening()
    }

    func onViewWillClose() {
        lingCastAspect.onConversationEnd()
        stopListeningIfNeeded()
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

        do {
            try TmkVoiceProcessingIO.configureAudioSession(sampleRate: 16000,
                                                           framesPerBuffer: 1024,
                                                           mode: .voiceChat,
                                                           useSpeaker: true)
        } catch {
            updateStatus("音频会话配置失败：\(error.localizedDescription)")
            Self.logger.info("startListening durationMs=\(self.durationMs(since: tapAt), privacy: .public) result=failure(audio_session)")
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
        _ completion: @escaping (Result<TmkSupportedLanguagesResponse, TmkTranslationError>) -> Void
    ) {
        guard isAuthVerified else {
            let error = TmkTranslationError.caller(message: "请先完成鉴权后再获取支持语言")
            updateStatus(error.localizedDescription)
            completion(.failure(error))
            return
        }
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

    func applyLanguages(source: String, target: String) {
        guard source != target else {
            updateStatus("源语言和目标语言不能相同")
            return
        }
        guard supportedLanguages.contains(source), supportedLanguages.contains(target) else {
            updateStatus("语言不在支持列表中")
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
        recreateRoomAndChannel()
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
}

private extension NowListeningViewModel {
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
                self.updateStatus("鉴权失败：\(error.localizedDescription)")
            }
        }
    }

    func createRoomAndChannel() {
        lingCastAspect.updateLanguages(source: selectedSourceLang, target: selectedTargetLang)
        lingCastAspect.onCreateRoomStarted()
        room = TmkTranslationSDK.shared.createTmkTranslationRoom(sourceLang: selectedSourceLang,
                                                                 targetLang: selectedTargetLang,
                                                                 scenario: .toSpeech,
                                                                 channelScenario: .listen) { [weak self] roomResult in
            guard let self else { return }
            switch roomResult {
            case .success(let room):
                self.lingCastAspect.onCreateRoomFinished(roomNo: room.channelDialogResponse?.roomNo ?? "", error: nil)
                self.createTranslationChannel(room: room)
            case .failure(let error):
                self.lingCastAspect.onCreateRoomFinished(roomNo: "", error: error)
                self.updateStatus("房间创建失败：\(error.localizedDescription)")
            }
        }
    }

    func createTranslationChannel(room: TmkTranslationRoom) {
        self.room = room
        refreshTargetPlaybackUIDs(from: room)

        let channelConfig = TmkTranslationChannelConfig.Builder()
            .setRoom(room)
            .setScenario(.listen)
            .setMode(.online)
            .setSourceLang(selectedSourceLang)
            .setTargetLang(selectedTargetLang)
            .setPCMSampleRate(16_000)
            .setPCMChannels(1)
            .build()

        updateStateOnMain {
            $0.currentRoomNo = room.channelDialogResponse?.roomNo ?? "-"
            $0.configuredSampleRate = channelConfig.pcmSampleRate
            $0.configuredChannels = channelConfig.pcmChannels
        }

        lingCastAspect.onJoinRoomStarted()
        lingCastAspect.onSubscribeStarted()
        TmkTranslationSDK.shared.createTranslationChannel(channelConfig, listener: self) { [weak self] channelResult in
            guard let self else { return }
            switch channelResult {
            case .success(let channel):
                self.channel = channel
                self.lingCastAspect.onJoinRoomFinished(error: nil)
                self.lingCastAspect.onSubscribeFinished(error: nil)
                self.updateStateOnMain {
                    $0.canStartListening = true
                }
                self.updateStatus("在线通道已就绪，点击“开始收听”开始采集")
            case .failure(let error):
                self.lingCastAspect.onJoinRoomFinished(error: error)
                self.lingCastAspect.onSubscribeFinished(error: error)
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
        closePCMFile()
        voiceIO = nil
        isPCMRecordingEnabled = false
        channel?.stop()
        channel = nil
        room = nil
        activePlaybackUID = nil
        updateStatus("已停止收听")
        Self.logger.info("channel stopped")
        lingCastAspect.onConversationEnd()
        closeRoomIfNeeded(closingRoom)
    }

    func recreateRoomAndChannel() {
        let closingRoom = room
        voiceIO?.stop()
        closePCMFile()
        setListeningActive(false)
        activePlaybackUID = nil
        targetPlaybackUIDs.removeAll()
        channel?.stop()
        channel = nil
        room = nil
        hasStoppedListening = false
        isPCMRecordingEnabled = false
        updateStateOnMain {
            $0.canStartListening = false
            $0.canStopListening = false
            $0.canSharePCM = false
            $0.playbackChannels = 0
        }
        updateStatus("语言已切换，重新创建通道中...")
        lingCastAspect.onConversationEnd()
        closeRoomIfNeeded(closingRoom)
        startOnlineListening()
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
        bubbleAssembler.reset()
        lastPublishedRows = []
        pendingRowsPublishWorkItem?.cancel()
        pendingRowsPublishWorkItem = nil
        rowMutation.send(.reset(rows: []))
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

    func closeRoomIfNeeded(_ room: TmkTranslationRoom?) {
        guard let room else { return }
        _ = room.closeRoom { result in
            switch result {
            case .success:
                Self.logger.info("close room success")
            case .failure(let error):
                Self.logger.error("close room failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

}

extension NowListeningViewModel: TmkTranslationListener {
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
        lingCastAspect.onSDKError(error)
        updateStatus("错误[\(error.category.rawValue)] \(error.message)")
    }

    func onEvent(name: String, args: Any?) {
        lingCastAspect.onEvent(name: name, args: args)
        if name == "online_started" {
            updateStatus("在线通道已就绪，点击“开始收听”开始采集")
        }
    }
}
