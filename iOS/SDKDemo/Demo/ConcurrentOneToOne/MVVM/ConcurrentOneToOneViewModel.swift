//
//  ConcurrentOneToOneViewModel.swift
//  TmkTranslationSDKDemo
//
//  Created by XiongJinhui on 2026/8/17.
//

import Foundation
import AVFAudio
import Combine
import OSLog
import TmkTranslationSDK

/// 对齐 Android ConcurrentOneToOneViewModel：唯一拥有双 Runtime、共享采集、Mapper 与 TTS 路由。
final class ConcurrentOneToOneViewModel: NSObject {
    private static let logger = Logger(subsystem: "co.timekettle.demo", category: "ConcurrentOneToOne")
    enum TTSSource: CaseIterable { case online, offline }
    @Published private(set) var state = ConcurrentOneToOneViewState()
    /// 一对一 Demo 的左右路语言。SDK 边界统一使用 source=右路、target=左路。
    private let leftLanguage: String
    private let rightLanguage: String
    private let mapper = ConcurrentConversationMapper()
    private let mapperQueue = DispatchQueue(label: "co.timekettle.demo.concurrent.mapper")
    private lazy var rowsCoalescer = DemoLatestKeyUpdateCoalescer<String>(
        interval: 0.1,
        scheduler: { interval, action in
            DispatchQueue.main.asyncAfter(deadline: .now() + interval, execute: action)
        },
        onFlush: { [weak self] _ in
            self?.mapperQueue.async { [weak self] in self?.publishRowsNow() }
        }
    )
    /// AudioUnit 回调只做有界入队；VAD、交错和双 Channel 推流均在串行队列执行。
    private let audioInputQueue = DispatchQueue(label: "co.timekettle.demo.concurrent.audio-input", qos: .userInitiated)
    private let audioInputSlots = DispatchSemaphore(value: 2)
    private let vadLock = NSLock()
    private var leftAudio: OneToOneLocalAudioLoopBuffer
    private var onlineChannel: TmkTranslationChannel?
    private var offlineChannel: TmkTranslationChannel?
    // SDK 结果分发器对业务 Listener 只保留弱引用；两路 Listener 必须由各自 Runtime 强持有。
    private var onlineListener: Listener?
    private var offlineListener: Listener?
    private var onlineRoomOperation: TmkSDKCancellable?
    private var onlineChannelOperation: TmkSDKCancellable?
    private var offlineChannelOperation: TmkSDKCancellable?
    private var voiceIO: TmkVoiceProcessingIO?
    private var ttsSource: TTSSource = .online
    private var playbackMode: OneToOnePlaybackMode = .left
    // 两路 Runtime 各持一个 TTS 封装类；TTS 来源(播在线还是离线)由 Listener 里的守卫决定。
    private lazy var onlineTtsCoordinator = DemoTtsPlaybackCoordinator(scene: .oneToOne)
    private lazy var offlineTtsCoordinator = DemoTtsPlaybackCoordinator(scene: .oneToOne)
    private let lifecycleLock = NSLock()
    private let channelLock = NSLock()
    private var sessionGeneration: UInt64 = 0
    /// 采集开关只在非 realtime 队列读取；AudioUnit 回调只负责有界入队。
    private var audioInputGeneration: UInt64?
    private var onlineGeneration: UInt64 = 0
    private var offlineGeneration: UInt64 = 0
    private let ttsLock = NSLock()
    private var modelDownloadGeneration: UInt64?
    private var onlineDidLogResult = false
    private var offlineDidLogResult = false
    private var released = false

    init(leftLanguage: String, rightLanguage: String) {
        self.leftLanguage = leftLanguage
        self.rightLanguage = rightLanguage
        let assetPath = Bundle.main.path(forResource: "right_audio", ofType: "pcm", inDirectory: "PCM")
            ?? Bundle.main.path(forResource: "right_audio", ofType: "pcm")
        self.leftAudio = OneToOneLocalAudioLoopBuffer(
            pcmData: assetPath.flatMap { try? Data(contentsOf: URL(fileURLWithPath: $0)) }
        )
        super.init()
    }

    deinit {
        release()
    }

    func prepare() {
        let generation = beginSession()
        onlineListener = nil
        offlineListener = nil
        onlineDidLogResult = false
        offlineDidLogResult = false
        mapperQueue.sync {
            rowsCoalescer.cancelAll()
            mapper.clear()
        }
        updateState {
            $0.onlineCanRetry = false
            $0.offlineCanRetry = false
            $0.modelTotalProgressText = ""
            $0.modelTotalProgress = 0
            $0.isModelDownloading = false
        }
        TmkTranslationSDK.shared.verifyAuth { [weak self] result in
            guard let self else { return }
            guard self.isCurrentSession(generation) else { return }
            switch result {
            case .success:
                self.prepareOnlineRuntime(generation: generation)
                self.prepareOfflineRuntime(generation: generation)
            case .failure(let error):
                self.updateState {
                    $0.onlineStatus = "鉴权失败：\(error.message)"
                    $0.offlineStatus = "鉴权失败：\(error.message)"
                    $0.onlineCanRetry = true
                    $0.offlineCanRetry = true
                }
            }
        }
    }

    func start() {
        guard state.canStart, !state.isRunning else { return }
        let generation = currentGeneration()
        let io = TmkVoiceProcessingIO(config: TmkVPConfig(sampleRate: 16_000, channels: 1, bitsPerChannel: 16, framesPerBuffer: 1024))
        voiceIO = io
        onlineTtsCoordinator.attach(voiceIO: io)
        offlineTtsCoordinator.attach(voiceIO: io)
        // 不在 AudioUnit realtime callback 中执行 VAD/交错/SDK 推流，避免音频线程被旁路处理拖慢。
        io.onInputPCM = { [weak self] data, _, _ in
            self?.enqueueAudioInput(data, sessionGeneration: generation)
        }
        io.requestRecordPermission { [weak self] granted in
            guard let self else { return }
            guard self.isCurrentSession(generation), self.voiceIO === io else { return }
            guard granted else { self.updateState { $0.onlineStatus = "麦克风权限未授权" }; return }
            do {
                try io.activateAudioSession(sampleRate: 16_000, framesPerBuffer: 1024, mode: .voiceChat, useSpeaker: true)
                self.setAudioInputGeneration(generation)
                try io.start()
                self.onlineTtsCoordinator.setActive(true)
                self.offlineTtsCoordinator.setActive(true)
                self.updateState { $0.isRunning = true }
            } catch {
                self.setAudioInputGeneration(nil)
                self.updateState { $0.onlineStatus = "音频启动失败：\(error.localizedDescription)" }
            }
        }
    }

    func stop() {
        setAudioInputGeneration(nil)
        voiceIO?.stop()
        onlineTtsCoordinator.setActive(false)
        offlineTtsCoordinator.setActive(false)
        voiceIO = nil
        updateState { $0.isRunning = false }
    }

    func retryOnline() {
        guard state.onlineCanRetry else { return }
        guard let generation = retryOnlineGeneration() else { return }
        onlineRoomOperation?.cancel(); onlineRoomOperation = nil
        onlineChannelOperation?.cancel(); onlineChannelOperation = nil
        takeChannel(.online)?.release()
        onlineListener = nil
        onlineDidLogResult = false
        let hasOfflineChannel = channel(for: .offline) != nil
        updateState { $0.onlineStatus = "重试中"; $0.onlineCanRetry = false; $0.canStart = hasOfflineChannel }
        prepareOnlineRuntime(generation: generation)
    }

    func retryOffline() {
        guard state.offlineCanRetry else { return }
        guard let generation = retryOfflineGeneration() else { return }
        offlineChannelOperation?.cancel(); offlineChannelOperation = nil
        takeChannel(.offline)?.release()
        offlineListener = nil
        offlineDidLogResult = false
        let hasOnlineChannel = channel(for: .online) != nil
        updateState { $0.offlineStatus = "重试中"; $0.offlineCanRetry = false; $0.canStart = hasOnlineChannel }
        prepareOfflineRuntime(generation: generation)
    }

    func selectTtsSource(_ source: TTSSource) {
        ttsLock.lock()
        ttsSource = source
        ttsLock.unlock()
        voiceIO?.clearPlaybackBuffer()
    }

    func selectPlaybackMode(_ mode: OneToOnePlaybackMode) {
        ttsLock.lock()
        playbackMode = mode
        ttsLock.unlock()
        onlineTtsCoordinator.setPlaybackMode(mode)
        offlineTtsCoordinator.setPlaybackMode(mode)
    }

    func currentTtsSourceForSettings() -> TTSSource {
        currentTtsSource()
    }

    func currentPlaybackModeForSettings() -> OneToOnePlaybackMode {
        currentPlaybackMode()
    }

    func downloadModels() {
        guard let generation = activeGeneration(), !state.isModelDownloading else { return }
        modelDownloadGeneration = generation
        updateState {
            $0.modelStatus = "下载中"
            $0.modelTotalProgress = 0
            $0.modelTotalProgressText = "总进度：0%"
            $0.isModelDownloading = true
            $0.offlineCanRetry = false
            $0.needsModelDownload = true
        }
        TmkTranslationSDK.shared.downloadOfflineModels(srcLang: rightLanguage, dstLang: leftLanguage, scenario: .oneToOne, needMt: true, needTts: true, listener: self)
    }

    func release() {
        guard invalidateSession() else { return }
        modelDownloadGeneration = nil
        onlineRoomOperation?.cancel(); onlineRoomOperation = nil
        onlineChannelOperation?.cancel(); onlineChannelOperation = nil
        offlineChannelOperation?.cancel(); offlineChannelOperation = nil
        stop()
        mapperQueue.async { [weak self] in
            guard let self else { return }
            self.rowsCoalescer.cancelAll()
            self.mapper.clear()
        }
        TmkTranslationSDK.shared.cancelOfflineModelDownload()
        TmkTranslationSDK.shared.releaseChannel()
        _ = takeChannel(.online)
        _ = takeChannel(.offline)
        onlineListener = nil
        offlineListener = nil
    }

    private func prepareOnlineRuntime(generation: UInt64) {
        guard isCurrent(.online, generation: generation) else { return }
        let profile = OneToOneDemoDefaults.concurrentOnline
        let speakers = [TmkSpeaker(channel: .left, gender: profile.leftSpeaker), TmkSpeaker(channel: .right, gender: profile.rightSpeaker)]
        // 在线 SDK 契约：左路固定 PCM 为 target，右路麦克风为 source。
        let redaction: TmkSensitiveWordRedactionOption = DemoSettingsStore().loadCurrentConfig().sensitiveWordRedactionEnabled ? .enabled : .disabled
        let roomConfig = TmkTranslationRoomConfig(sourceLang: rightLanguage, targetLang: leftLanguage, scenario: profile.roomScenario, channelScenario: .oneToOne, speakers: speakers, translateEngine: profile.translateEngine, recognizeEngine: profile.recognizeEngine, translateMode: profile.translateMode, dialogConversationAudioMode: profile.audioMode, enableSensitiveWordRedaction: redaction)
        onlineRoomOperation = TmkTranslationSDK.shared.createTmkTranslationRoom(config: roomConfig) { [weak self] result in
            guard let self else { return }
            guard self.isCurrent(.online, generation: generation) else { return }
            self.onlineRoomOperation = nil
            switch result {
            case .success(let room):
                guard self.isCurrent(.online, generation: generation) else { return }
                let config = TmkTranslationChannelConfig.Builder().setRoom(room).setScenario(.oneToOne).setMode(.online).setSourceLang(self.rightLanguage).setTargetLang(self.leftLanguage).setSpeakers(speakers).setPCMSampleRate(OneToOneDemoDefaults.sampleRate).setPCMChannels(OneToOneDemoDefaults.channelCount).build()
                let listener = Listener(owner: self, runtime: .online, generation: generation)
                self.onlineListener = listener
                self.onlineChannelOperation = TmkTranslationSDK.shared.createTranslationChannel(config, listener: listener) { [weak self] result in self?.bind(result, runtime: .online, generation: generation) }
            case .failure(let error):
                self.updateState(runtime: .online, generation: generation) {
                    $0.onlineStatus = "建房失败：\(error.message)"
                    $0.onlineCanRetry = true
                }
            }
        }
    }

    private func prepareOfflineRuntime(generation: UInt64) {
        guard isCurrent(.offline, generation: generation) else { return }
        guard TmkTranslationSDK.shared.isOfflineTranslationSupported() else { updateState { $0.offlineStatus = "当前账号未开通离线能力"; $0.modelStatus = "不可用"; $0.offlineCanRetry = false }; return }
        guard TmkTranslationSDK.shared.isOfflineModelReady(srcLang: rightLanguage, dstLang: leftLanguage, scenario: .oneToOne, needMt: true, needTts: true) else { updateState { $0.offlineStatus = "模型缺失"; $0.modelStatus = "需要下载"; $0.needsModelDownload = true; $0.offlineCanRetry = false }; return }
        let profile = OneToOneDemoDefaults.concurrentOffline
        let speakers = [TmkSpeaker(channel: .left, gender: profile.leftSpeaker), TmkSpeaker(channel: .right, gender: profile.rightSpeaker)]
        let config = TmkTranslationChannelConfig.Builder().setMode(.offline).setScenario(.oneToOne).setSourceLang(rightLanguage).setTargetLang(leftLanguage).setSpeakers(speakers).setPCMSampleRate(OneToOneDemoDefaults.sampleRate).setPCMChannels(OneToOneDemoDefaults.channelCount).setChannelAudioMode(profile.audioMode).setModelRootDirectory(OneToOneDemoDefaults.offlineModelRootDirectory()).setTranslateMode(profile.translateMode).setCapabilityTier(.toSpeech).build()
        let listener = Listener(owner: self, runtime: .offline, generation: generation)
        offlineListener = listener
        offlineChannelOperation = TmkTranslationSDK.shared.createTranslationChannel(config, listener: listener) { [weak self] result in self?.bind(result, runtime: .offline, generation: generation) }
    }

    private func bind(_ result: Result<TmkTranslationChannel, TmkTranslationError>, runtime: ConcurrentConversationMapper.Runtime, generation: UInt64) {
        guard isCurrent(runtime, generation: generation) else {
            if case .success(let channel) = result { channel.release() }
            return
        }
        switch result {
        case .success(let channel):
            if runtime == .online { onlineChannelOperation = nil } else { offlineChannelOperation = nil }
            setChannel(channel, for: runtime)
            if runtime == .online {
                updateState(runtime: runtime, generation: generation) {
                    $0.onlineStatus = "已就绪"
                    $0.onlineCanRetry = false
                    $0.canStart = true
                }
            } else {
                updateState(runtime: runtime, generation: generation) {
                    $0.offlineStatus = "已就绪"
                    $0.offlineCanRetry = false
                    $0.modelStatus = "模型已就绪"
                    $0.modelTotalProgressText = ""
                    $0.isModelDownloading = false
                    $0.needsModelDownload = false
                    $0.canStart = true
                }
            }
            let runtimeName = runtime == .online ? "ONLINE" : "OFFLINE"
            Self.logger.info("runtime=\(runtimeName) channel created and listener retained")
        case .failure(let error):
            if runtime == .online { onlineChannelOperation = nil } else { offlineChannelOperation = nil }
            if runtime == .online { onlineListener = nil } else { offlineListener = nil }
            let runtimeName = runtime == .online ? "ONLINE" : "OFFLINE"
            Self.logger.error("runtime=\(runtimeName) channel creation failed")
            updateState(runtime: runtime, generation: generation) {
                if runtime == .online { $0.onlineStatus = "建通道失败：\(error.message)"; $0.onlineCanRetry = true }
                else { $0.offlineStatus = "建通道失败：\(error.message)"; $0.offlineCanRetry = true }
            }
        }
    }

    private func enqueueAudioInput(_ data: Data, sessionGeneration: UInt64) {
        // AudioUnit realtime callback 不获取生命周期锁；停止后的排队数据由工作队列代际校验丢弃。
        guard !data.isEmpty, audioInputSlots.wait(timeout: .now()) == .success else { return }
        audioInputQueue.async { [weak self] in
            defer { self?.audioInputSlots.signal() }
            guard let self,
                  self.isCurrentSession(sessionGeneration),
                  self.isAudioInputEnabled(sessionGeneration) else { return }
            let vadState: TmkVoiceProcessingIO.VADState = .silence
            self.routeAudio(mic: data, vadState: vadState, sessionGeneration: sessionGeneration)
        }
    }

    private func routeAudio(mic: Data,
                            vadState: TmkVoiceProcessingIO.VADState,
                            sessionGeneration: UInt64) {
        guard !mic.isEmpty, isCurrentSession(sessionGeneration) else { return }
        let chunk = leftAudio.nextLoopChunk(expectedLength: mic.count)
        let stereo = interleave(left: chunk.data, right: mic)
        let channels = channelSnapshot()
        channels.online?.pushStreamAudioData(stereo, channelCount: 2, extraChunk: nil)
        channels.offline?.pushStreamAudioData(stereo, channelCount: 2, extraChunk: nil)
    }

    private func consume(_ runtime: ConcurrentConversationMapper.Runtime, generation: UInt64, kind: ConcurrentConversationMapper.Kind, result: TmkResult<String>, isFinal: Bool) {
        guard isCurrent(runtime, generation: generation) else { return }
        if runtime == .online {
            if onlineDidLogResult == false {
                onlineDidLogResult = true
                let kindName = kind == .asr ? "ASR" : "MT"
                Self.logger.info("runtime=ONLINE listener callback kind=\(kindName) final=\(isFinal)")
            }
        } else if offlineDidLogResult == false {
            offlineDidLogResult = true
            let kindName = kind == .asr ? "ASR" : "MT"
            Self.logger.info("runtime=OFFLINE listener callback kind=\(kindName) final=\(isFinal)")
        }
        let event: DemoConversationEvent?
        switch kind {
        case .asr:
            event = DemoConversationEventAdapter.makeRecognizedEvent(from: result, isFinal: isFinal)
        case .mt:
            event = DemoConversationEventAdapter.makeTranslatedEvent(from: result, isFinal: isFinal)
        }
        guard let event else { return }
        mapperQueue.async { [weak self] in
            guard let self, self.isCurrent(runtime, generation: generation) else { return }
            _ = self.mapper.consume(runtime: runtime, event: event)
            if isFinal { self.rowsCoalescer.flush("rows") } else { self.publishRows() }
        }
    }

    /// 结果回调只提交刷新 key，避免每个 partial 都触发一次 UITableView 全量刷新。
    private func publishRows() { rowsCoalescer.submit("rows") }

    private func publishRowsNow() {
        let rows = mapper.rows()
        updateState { $0.rows = rows }
    }
    private func interleave(left: Data, right: Data) -> Data { let count = min(left.count, right.count) / 2; var output = Data(capacity: count * 4); left.withUnsafeBytes { l in right.withUnsafeBytes { r in guard let lb = l.bindMemory(to: UInt8.self).baseAddress, let rb = r.bindMemory(to: UInt8.self).baseAddress else { return }; for i in 0..<count { output.append(lb[i * 2]); output.append(lb[i * 2 + 1]); output.append(rb[i * 2]); output.append(rb[i * 2 + 1]) } } }; return output }
    private func channel(for runtime: ConcurrentConversationMapper.Runtime) -> TmkTranslationChannel? {
        channelLock.lock()
        defer { channelLock.unlock() }
        return runtime == .online ? onlineChannel : offlineChannel
    }

    private func setChannel(_ channel: TmkTranslationChannel?, for runtime: ConcurrentConversationMapper.Runtime) {
        channelLock.lock()
        if runtime == .online { onlineChannel = channel } else { offlineChannel = channel }
        channelLock.unlock()
    }

    private func takeChannel(_ runtime: ConcurrentConversationMapper.Runtime) -> TmkTranslationChannel? {
        channelLock.lock()
        let channel: TmkTranslationChannel?
        if runtime == .online {
            channel = onlineChannel
            onlineChannel = nil
        } else {
            channel = offlineChannel
            offlineChannel = nil
        }
        channelLock.unlock()
        return channel
    }

    private func channelSnapshot() -> (online: TmkTranslationChannel?, offline: TmkTranslationChannel?) {
        channelLock.lock()
        let snapshot = (online: onlineChannel, offline: offlineChannel)
        channelLock.unlock()
        return snapshot
    }

    private func updateState(runtime: ConcurrentConversationMapper.Runtime? = nil,
                             generation: UInt64? = nil,
                             _ mutate: @escaping (inout ConcurrentOneToOneViewState) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let runtime, let generation {
                guard self.isCurrent(runtime, generation: generation) else { return }
            } else {
                guard self.activeGeneration() != nil else { return }
            }
            var state = self.state
            mutate(&state)
            self.state = state
        }
    }

    private func handleRuntimeError(_ runtime: ConcurrentConversationMapper.Runtime, generation: UInt64, message: String) {
        guard isCurrent(runtime, generation: generation) else { return }
        updateState(runtime: runtime, generation: generation) {
            if runtime == .online {
                $0.onlineStatus = "错误：\(message)"
                $0.onlineCanRetry = true
            } else {
                $0.offlineStatus = "错误：\(message)"
                $0.offlineCanRetry = true
            }
        }
    }

    private func beginSession() -> UInt64 {
        lifecycleLock.lock()
        sessionGeneration &+= 1
        onlineGeneration = sessionGeneration
        offlineGeneration = sessionGeneration
        released = false
        let generation = sessionGeneration
        lifecycleLock.unlock()
        return generation
    }

    @discardableResult
    private func invalidateSession() -> Bool {
        lifecycleLock.lock()
        guard !released else {
            lifecycleLock.unlock()
            return false
        }
        released = true
        sessionGeneration &+= 1
        lifecycleLock.unlock()
        return true
    }

    private func currentGeneration() -> UInt64 {
        lifecycleLock.lock()
        let generation = sessionGeneration
        lifecycleLock.unlock()
        return generation
    }

    private func setAudioInputGeneration(_ generation: UInt64?) {
        lifecycleLock.lock()
        audioInputGeneration = generation
        lifecycleLock.unlock()
    }

    private func isAudioInputEnabled(_ generation: UInt64) -> Bool {
        lifecycleLock.lock()
        let enabled = !released && audioInputGeneration == generation
        lifecycleLock.unlock()
        return enabled
    }

    private func currentRuntimeGeneration(_ runtime: ConcurrentConversationMapper.Runtime) -> UInt64 {
        lifecycleLock.lock()
        let generation = runtime == .online ? onlineGeneration : offlineGeneration
        lifecycleLock.unlock()
        return generation
    }

    private func activeGeneration() -> UInt64? {
        lifecycleLock.lock()
        let generation = released ? nil : sessionGeneration
        lifecycleLock.unlock()
        return generation
    }

    private func retryOnlineGeneration() -> UInt64? {
        lifecycleLock.lock()
        guard !released else {
            lifecycleLock.unlock()
            return nil
        }
        onlineGeneration &+= 1
        let generation = onlineGeneration
        lifecycleLock.unlock()
        return generation
    }

    private func retryOfflineGeneration() -> UInt64? {
        lifecycleLock.lock()
        guard !released else {
            lifecycleLock.unlock()
            return nil
        }
        offlineGeneration &+= 1
        let generation = offlineGeneration
        lifecycleLock.unlock()
        return generation
    }

    fileprivate func isCurrentSession(_ generation: UInt64) -> Bool {
        lifecycleLock.lock()
        let result = !released && sessionGeneration == generation
        lifecycleLock.unlock()
        return result
    }

    fileprivate func isCurrent(_ runtime: ConcurrentConversationMapper.Runtime, generation: UInt64) -> Bool {
        lifecycleLock.lock()
        let runtimeGeneration = runtime == .online ? onlineGeneration : offlineGeneration
        let result = !released && runtimeGeneration == generation
        lifecycleLock.unlock()
        return result
    }

    private func currentTtsSource() -> TTSSource {
        ttsLock.lock()
        let source = ttsSource
        ttsLock.unlock()
        return source
    }

    private func currentPlaybackMode() -> OneToOnePlaybackMode {
        ttsLock.lock()
        let mode = playbackMode
        ttsLock.unlock()
        return mode
    }

    private final class Listener: TmkTranslationListener {
        weak var owner: ConcurrentOneToOneViewModel?
        let runtime: ConcurrentConversationMapper.Runtime
        let generation: UInt64
        init(owner: ConcurrentOneToOneViewModel, runtime: ConcurrentConversationMapper.Runtime, generation: UInt64) { self.owner = owner; self.runtime = runtime; self.generation = generation }
        func onRecognized(from engine: AbstractChannelEngine, result: TmkResult<String>, isFinal: Bool) { owner?.consume(runtime, generation: generation, kind: .asr, result: result, isFinal: isFinal) }
        func onTranslate(from engine: AbstractChannelEngine, result: TmkResult<String>, isFinal: Bool) { owner?.consume(runtime, generation: generation, kind: .mt, result: result, isFinal: isFinal) }
        func onAudioDataReceive(from engine: AbstractChannelEngine, result: TmkResult<String>, data: Data, channelCount: Int) {
            guard let owner, owner.isCurrent(runtime, generation: generation), result.data == "translated_audio", !data.isEmpty else { return }
            let selectedSource = owner.currentTtsSource()
            guard (runtime == .online && selectedSource == .online) || (runtime == .offline && selectedSource == .offline) else { return }
            let coordinator = runtime == .online ? owner.onlineTtsCoordinator : owner.offlineTtsCoordinator
            coordinator.handleAudioData(result: result, data: data, channelCount: channelCount)
        }
        func onError(_ error: TmkTranslationError) {
            owner?.handleRuntimeError(runtime, generation: generation, message: error.message)
        }
        func onError(code: Int, message: String) {
            owner?.handleRuntimeError(runtime, generation: generation, message: message)
        }
        func onEvent(name: String, args: Any?) {}
        func onStateChanged(from engine: AbstractChannelEngine, snapshot: TmkTranslationChannelStateSnapshot) {}
    }
}

extension ConcurrentOneToOneViewModel: TmkOfflineModelDownloadListener {
    func onOfflineModelReady() {
        guard let downloadGeneration = modelDownloadGeneration, isCurrentSession(downloadGeneration) else { return }
        let generation = currentRuntimeGeneration(.offline)
        updateState {
            $0.modelStatus = "模型已就绪"
            $0.modelTotalProgress = 1
            $0.modelTotalProgressText = "总进度：100%"
            $0.isModelDownloading = false
            $0.needsModelDownload = false
            $0.offlineCanRetry = false
        }
        prepareOfflineRuntime(generation: generation)
    }
    func onOfflineModelDownloadProgress(fileName: String, index: Int, total: Int, downloaded: Int64, fileTotal: Int64) {
        guard let generation = modelDownloadGeneration, isCurrentSession(generation) else { return }
        _ = generation
        updateState {
            $0.modelStatus = "下载中 (\(index)/\(total))"
            $0.isModelDownloading = true
            $0.offlineCanRetry = false
        }
    }
    func onOfflineModelTotalProgress(downloadedBytesAll: Int64, totalBytesAll: Int64) {
        guard let generation = modelDownloadGeneration, isCurrentSession(generation) else { return }
        let progress = totalBytesAll > 0
            ? min(max(Double(downloadedBytesAll) / Double(totalBytesAll), 0), 1)
            : 0
        let percent = totalBytesAll > 0 ? "\(Int(progress * 100))%" : "计算中"
        let downloadedText = formatBytes(downloadedBytesAll)
        let totalText = totalBytesAll > 0 ? formatBytes(totalBytesAll) : "未知"
        updateState {
            $0.modelTotalProgress = progress
            $0.modelTotalProgressText = "总进度：\(percent)（\(downloadedText) / \(totalText)）"
            $0.isModelDownloading = true
            $0.offlineCanRetry = false
        }
    }
    func onOfflineModelError(_ error: TmkTranslationError) {
        guard let generation = modelDownloadGeneration, isCurrentSession(generation) else { return }
        _ = generation
        updateState {
            $0.modelStatus = "下载失败：\(error.message)"
            $0.modelTotalProgressText = "总进度：下载失败"
            $0.isModelDownloading = false
            $0.needsModelDownload = true
            $0.offlineCanRetry = false
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        guard bytes >= 1024 else { return "\(bytes) B" }
        let units = ["B", "KB", "MB", "GB"]
        var value = Double(bytes)
        var index = 0
        while value >= 1024, index < units.count - 1 {
            value /= 1024
            index += 1
        }
        return String(format: "%.1f %@", value, units[index])
    }
}
