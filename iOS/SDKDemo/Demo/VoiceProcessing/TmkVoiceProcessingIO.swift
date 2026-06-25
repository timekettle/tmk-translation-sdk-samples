//
//  TmkVoiceProcessingIO.swift
//  TmkTranslationSDKDemo
//
//  基于 VoiceProcessingIO 的边录边播
//  说明：
//  - 录音数据通过 onInputPCM 回调给业务层
//  - 业务层处理后（如翻译/降噪/变声）再调用 enqueuePlaybackPCM 推入播放队列
//  - 播放输出使用 VoiceProcessingIO 的输出回调实时消费队列
//

import Foundation
import AudioToolbox
import AVFoundation
import OSLog

final class TmkVoiceProcessingIO {
    enum State {
        case idle
        case running
        case paused
        case stopped
    }

    enum VADState: String {
        case speechStart
        case speeching
        case speechEnd
        case silence
    }

    /// 采集中断相关事件，业务层据此更新 UI 文案/按钮状态。
    enum InterruptionEvent {
        /// 录音被系统中断（来电、Siri、闹钟等），采集已暂停。
        case interrupted
        /// 中断结束后采集已自动恢复。
        case resumed
        /// 中断结束后自动恢复失败，需要业务层提示并允许用户重试。
        case resumeFailed(Error)
    }

    // 录音数据回调（业务层拿到后自行处理）
    typealias InputPCMHandler = (_ pcmData: Data, _ format: AudioStreamBasicDescription, _ vadState: VADState) -> Void
    typealias VADStateResolver = (_ pcmData: Data, _ format: AudioStreamBasicDescription) -> VADState

    // 记录最近一次激活会话所用参数，用于中断结束后由自身重新激活会话。
    private struct AudioSessionSetup {
        let sampleRate: Double
        let framesPerBuffer: UInt32
        let mode: AVAudioSession.Mode
        let useSpeaker: Bool
    }

    // 采样配置
    private let config: TmkVPConfig
    // 当前 AudioUnit 实际生效的格式（可能和请求值不同，例如立体声回退到单声道）
    private var activeStreamDescription: AudioStreamBasicDescription
    // AudioUnit 实例（VoiceProcessingIO）
    private var audioUnit: AudioUnit?
    // 播放环形缓冲区（存放业务层处理后的 PCM）
    private let playbackBuffer: TmkRingBuffer
    // 当前状态
    private var state: State = .idle
    // 状态锁
    private let stateLock = NSLock()

    // 录音回调（业务层获取原始 PCM）
    var onInputPCM: InputPCMHandler?
    // VAD 状态由业务层外部注入；未设置时表示当前不启用 VAD，回调中的 vadState 无实际语义。
    var resolveVADState: VADStateResolver?
    // 采集中断/恢复事件回调（统一切回主线程触发），业务层据此更新 UI。
    var onInterruptionEvent: ((InterruptionEvent) -> Void)?
    // 外部可读取当前实际采集声道数
    var activeChannels: UInt32 { activeStreamDescription.mChannelsPerFrame }

    private static let logger = Logger(subsystem: "co.timekettle.demo", category: "VoiceProcessingIO")
    // 最近一次会话激活参数，供中断结束/服务重置后自身重新激活会话使用。
    private var lastSessionSetup: AudioSessionSetup?
    // 是否处于「运行中被系统中断」状态，仅此情况下在中断结束时自动恢复。
    private var interruptedWhileRunning = false
    // 已注册的系统通知 observer token，stop()/deinit 时精确移除，避免重复注册与误响应。
    private var notificationTokens: [NSObjectProtocol] = []
    // 串行化所有中断恢复动作，避免多通知并发重入 AudioUnit 操作。
    private let interruptionQueue = DispatchQueue(label: "co.timekettle.demo.voiceio.interruption")

    init(config: TmkVPConfig = TmkVPConfig()) {
        self.config = config
        self.activeStreamDescription = config.streamDescription
        let capacityFrames = Int(config.sampleRate * 20) // 20 秒缓冲，避免快速连续翻译时覆盖前段音频
        let capacitySamples = capacityFrames * Int(config.channels)
        self.playbackBuffer = TmkRingBuffer(capacity: capacitySamples)
    }

    deinit {
        stop()
        disposeAudioUnit()
    }

    // 业务层将处理后的 PCM 推入播放队列（int16 + interleaved）
    func enqueuePlaybackPCM(_ data: Data) {
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            let count = data.count / MemoryLayout<Int16>.size
            playbackBuffer.write(base.assumingMemoryBound(to: Int16.self), count: count)
        }
    }

    /// 清空播放缓存，用于播放音源切换时丢弃旧数据，避免旧声道残留。
    func clearPlaybackBuffer() {
        playbackBuffer.reset()
    }

    // 请求麦克风权限
    func requestRecordPermission(_ completion: @escaping (Bool) -> Void) {
        if #available(iOS 17.0, *) {
            AVAudioApplication.requestRecordPermission { granted in
                DispatchQueue.main.async {
                    completion(granted)
                }
            }
        } else {
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                DispatchQueue.main.async {
                    completion(granted)
                }
            }
        }
    }

    // 调用方按场景配置 AVAudioSession（边录边播）
    // 建议：
    // - mode: .voiceChat / .videoChat 用于回声消除
    // - useSpeaker: true 走外放，false 走听筒
    static func configureAudioSession(sampleRate: Double,
                                      framesPerBuffer: UInt32,
                                      mode: AVAudioSession.Mode = .voiceChat,
                                      useSpeaker: Bool = true) throws {
        let session = AVAudioSession.sharedInstance()
        var options: AVAudioSession.CategoryOptions = [.allowBluetoothHFP]
        if useSpeaker {
            options.insert(.defaultToSpeaker)
        }
        try session.setCategory(.playAndRecord, mode: mode, options: options)
        try session.setPreferredSampleRate(sampleRate)
        try session.setPreferredIOBufferDuration(Double(framesPerBuffer) / sampleRate)
        try session.setActive(true, options: [])
        if useSpeaker {
            try session.overrideOutputAudioPort(.speaker)
        } else {
            try session.overrideOutputAudioPort(.none)
        }
    }

    /// 激活会话并记住参数，使录音器在中断结束/服务重置后能自行重新激活。
    /// 业务层应改用本实例方法替代直接调用 static configureAudioSession。
    func activateAudioSession(sampleRate: Double,
                              framesPerBuffer: UInt32,
                              mode: AVAudioSession.Mode = .voiceChat,
                              useSpeaker: Bool = true) throws {
        try Self.configureAudioSession(sampleRate: sampleRate,
                                       framesPerBuffer: framesPerBuffer,
                                       mode: mode,
                                       useSpeaker: useSpeaker)
        lastSessionSetup = AudioSessionSetup(sampleRate: sampleRate,
                                             framesPerBuffer: framesPerBuffer,
                                             mode: mode,
                                             useSpeaker: useSpeaker)
    }

    // 启动音频单元（开始采集与播放）
    func start() throws {
        if isRunning { return }
        if audioUnit == nil {
            try createAudioUnit()
        }
        let status = AudioOutputUnitStart(audioUnit!)
        try Self.check(status)
        setState(.running)
        registerInterruptionObserversIfNeeded()
    }

    // 暂停（停止回调但保留 AudioUnit）
    func pause() throws {
        guard isRunning else { return }
        let status = AudioOutputUnitStop(audioUnit!)
        try Self.check(status)
        setState(.paused)
    }

    // 继续
    func resume() throws {
        guard state == .paused else { return }
        let status = AudioOutputUnitStart(audioUnit!)
        try Self.check(status)
        setState(.running)
    }

    // 停止并清空播放缓冲
    func stop() {
        removeInterruptionObservers()
        interruptedWhileRunning = false
        guard let unit = audioUnit else { return }
        setState(.stopped)
        AudioOutputUnitStop(unit)
        playbackBuffer.reset()
    }

    // MARK: - 中断 / 路由变化 / 服务重置处理

    /// 注册系统音频通知（仅在采集运行后注册一次）。
    private func registerInterruptionObserversIfNeeded() {
        guard notificationTokens.isEmpty else { return }
        let center = NotificationCenter.default
        let interruption = center.addObserver(forName: AVAudioSession.interruptionNotification,
                                              object: nil,
                                              queue: nil) { [weak self] note in
            self?.handleInterruption(note)
        }
        let routeChange = center.addObserver(forName: AVAudioSession.routeChangeNotification,
                                             object: nil,
                                             queue: nil) { [weak self] note in
            self?.handleRouteChange(note)
        }
        let reset = center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification,
                                       object: nil,
                                       queue: nil) { [weak self] _ in
            self?.handleMediaServicesReset()
        }
        notificationTokens = [interruption, routeChange, reset]
    }

    /// 注销系统音频通知。
    private func removeInterruptionObservers() {
        let center = NotificationCenter.default
        notificationTokens.forEach { center.removeObserver($0) }
        notificationTokens.removeAll()
    }

    /// 处理中断通知：来电/Siri/闹钟等。
    private func handleInterruption(_ note: Notification) {
        guard let info = note.userInfo,
              let rawType = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }

        switch type {
        case .began:
            interruptionQueue.async { [weak self] in
                guard let self else { return }
                guard self.isRunning else { return }
                self.interruptedWhileRunning = true
                try? self.pause()
                Self.logger.info("interruption began -> paused")
                self.emitEvent(.interrupted)
            }
        case .ended:
            // 部分通话场景 .shouldResume 不可靠，这里只要此前确为运行中被中断，就尝试恢复。
            interruptionQueue.async { [weak self] in
                guard let self else { return }
                guard self.interruptedWhileRunning else { return }
                self.interruptedWhileRunning = false
                self.recoverCapture(reason: "interruptionEnded", rebuild: false)
            }
        @unknown default:
            break
        }
    }

    /// 处理路由变化：拔出耳机等导致采集停摆时自动恢复。
    private func handleRouteChange(_ note: Notification) {
        guard let info = note.userInfo,
              let rawReason = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: rawReason) else { return }
        // 仅在旧设备不可用（如拔出耳机）时介入；其余路由变化由系统平滑处理。
        guard reason == .oldDeviceUnavailable else { return }
        interruptionQueue.async { [weak self] in
            guard let self else { return }
            // 仅在采集仍为 .running 时介入：业务层主动 pause()(state == .paused)不应被路由变化自动恢复。
            guard self.isRunning else { return }
            // 拔耳机后 AudioUnit 已被系统停掉但 state 仍为 .running，resume 无法复位，故走完整重建。
            self.recoverCapture(reason: "routeChange", rebuild: true)
        }
    }

    /// 处理音频服务重置：AudioUnit 句柄已失效，必须完整重建。
    private func handleMediaServicesReset() {
        interruptionQueue.async { [weak self] in
            guard let self else { return }
            guard self.shouldBeCapturing else { return }
            self.interruptedWhileRunning = false
            self.recoverCapture(reason: "mediaServicesReset", rebuild: true)
        }
    }

    /// 统一的采集恢复入口（已在 interruptionQueue 串行执行）。
    /// - Parameter rebuild: 是否需要先销毁并重建 AudioUnit（服务重置场景为 true）。
    private func recoverCapture(reason: String, rebuild: Bool) {
        guard let setup = lastSessionSetup else {
            Self.logger.error("recoverCapture(\(reason, privacy: .public)) skipped: no session setup")
            emitEvent(.resumeFailed(NSError(domain: "TmkVoiceProcessingIO",
                                            code: -10,
                                            userInfo: [NSLocalizedDescriptionKey: "缺少会话配置，无法恢复采集"])))
            return
        }
        do {
            try Self.configureAudioSession(sampleRate: setup.sampleRate,
                                           framesPerBuffer: setup.framesPerBuffer,
                                           mode: setup.mode,
                                           useSpeaker: setup.useSpeaker)
            if rebuild {
                disposeAudioUnit()
                setState(.idle)
                try start()
            } else {
                do {
                    try resume()
                } catch {
                    // resume 失败兜底：销毁后完整重建采集单元。
                    Self.logger.error("resume failed, rebuilding: \(error.localizedDescription, privacy: .public)")
                    disposeAudioUnit()
                    setState(.idle)
                    try start()
                }
            }
            Self.logger.info("recoverCapture(\(reason, privacy: .public)) success rebuild=\(rebuild, privacy: .public)")
            emitEvent(.resumed)
        } catch {
            Self.logger.error("recoverCapture(\(reason, privacy: .public)) failed: \(error.localizedDescription, privacy: .public)")
            emitEvent(.resumeFailed(error))
        }
    }

    /// 当前是否应处于采集状态（运行中或因中断暂停）。
    private var shouldBeCapturing: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return state == .running || state == .paused
    }

    /// 统一切回主线程触发对外事件。
    private func emitEvent(_ event: InterruptionEvent) {
        guard let handler = onInterruptionEvent else { return }
        DispatchQueue.main.async {
            handler(event)
        }
    }

    // 创建并配置 VoiceProcessingIO
    private func createAudioUnit() throws {
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_VoiceProcessingIO,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )

        guard let comp = AudioComponentFindNext(nil, &desc) else {
            throw NSError(domain: "TmkVoiceProcessingIO", code: -1, userInfo: [NSLocalizedDescriptionKey: "AudioComponent not found"])
        }

        var unit: AudioUnit?
        try Self.check(AudioComponentInstanceNew(comp, &unit))
        audioUnit = unit

        // 开启输入与输出
        var enableIO: UInt32 = 1
        try Self.check(AudioUnitSetProperty(unit!, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &enableIO, UInt32(MemoryLayout<UInt32>.size)))
        try Self.check(AudioUnitSetProperty(unit!, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &enableIO, UInt32(MemoryLayout<UInt32>.size)))

        // 设置音频格式（优先按配置生效；若立体声不被 VoiceProcessingIO 接收，自动回退到单声道）
        let configuredASBD = config.streamDescription
        let finalASBD = try configureStreamFormat(unit: unit!, preferred: configuredASBD)
        activeStreamDescription = finalASBD

        // 输入回调（录音）
        var inputCallback = AURenderCallbackStruct(
            inputProc: TmkVoiceProcessingIO.inputCallback,
            inputProcRefCon: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        )
        try Self.check(AudioUnitSetProperty(unit!, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 1, &inputCallback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)))

        // 输出回调（播放）
        var outputCallback = AURenderCallbackStruct(
            inputProc: TmkVoiceProcessingIO.outputCallback,
            inputProcRefCon: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        )
        try Self.check(AudioUnitSetProperty(unit!, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &outputCallback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)))

        try Self.check(AudioUnitInitialize(unit!))
    }

    private func disposeAudioUnit() {
        if let unit = audioUnit {
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
            audioUnit = nil
        }
    }

    private static let inputCallback: AURenderCallback = { refCon, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, ioData in
        let instance = Unmanaged<TmkVoiceProcessingIO>.fromOpaque(refCon).takeUnretainedValue()
        return instance.handleInput(inTimeStamp: inTimeStamp, inBusNumber: inBusNumber, inNumberFrames: inNumberFrames)
    }

    private static let outputCallback: AURenderCallback = { refCon, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, ioData in
        guard let ioData else { return noErr }
        let instance = Unmanaged<TmkVoiceProcessingIO>.fromOpaque(refCon).takeUnretainedValue()
        return instance.handleOutput(ioData: ioData, inNumberFrames: inNumberFrames)
    }

    // 处理录音输入：拉取麦克风数据 -> 回调给业务层
    private func handleInput(inTimeStamp: UnsafePointer<AudioTimeStamp>, inBusNumber: UInt32, inNumberFrames: UInt32) -> OSStatus {
        guard let unit = audioUnit else { return noErr }

        var bufferList = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(
                mNumberChannels: activeStreamDescription.mChannelsPerFrame,
                mDataByteSize: inNumberFrames * activeBytesPerFrame,
                mData: nil
            )
        )

        let status = AudioUnitRender(unit, nil, inTimeStamp, 1, inNumberFrames, &bufferList)
        if status != noErr {
            return status
        }

        if let dataPtr = bufferList.mBuffers.mData {
            let byteSize = Int(bufferList.mBuffers.mDataByteSize)
            let data = Data(bytes: dataPtr, count: byteSize)
            let vadState = resolveVADState?(data, activeStreamDescription) ?? .silence
            onInputPCM?(data, activeStreamDescription, vadState)
        }

        return noErr
    }

    // 处理播放输出：从业务层缓存中取出 PCM 送给扬声器
    private func handleOutput(ioData: UnsafeMutablePointer<AudioBufferList>, inNumberFrames: UInt32) -> OSStatus {
        let buffer = ioData.pointee.mBuffers
        let byteSize = Int(inNumberFrames * activeBytesPerFrame)
        if let dataPtr = buffer.mData {
            let sampleCount = byteSize / MemoryLayout<Int16>.size
            let written = playbackBuffer.read(dataPtr.assumingMemoryBound(to: Int16.self), count: sampleCount)
            if written < sampleCount {
                // 补零
                let remain = sampleCount - written
                let dst = dataPtr.assumingMemoryBound(to: Int16.self)
                memset(dst.advanced(by: written), 0, remain * MemoryLayout<Int16>.size)
            }
            ioData.pointee.mBuffers.mDataByteSize = UInt32(byteSize)
        }
        return noErr
    }

    private var isRunning: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return state == .running
    }

    private func setState(_ newState: State) {
        stateLock.lock()
        state = newState
        stateLock.unlock()
    }

    private static func check(_ status: OSStatus) throws {
        guard status == noErr else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [
                NSLocalizedDescriptionKey: "AudioUnit error: \(status)"
            ])
        }
    }

    private var activeBytesPerFrame: UInt32 {
        activeStreamDescription.mBytesPerFrame
    }

    private func configureStreamFormat(unit: AudioUnit, preferred: AudioStreamBasicDescription) throws -> AudioStreamBasicDescription {
        var requested = preferred
        do {
            try setStreamFormat(unit: unit, asbd: &requested)
            // 读取播放侧实际生效格式，避免外部按“请求值”推流导致声道不一致。
            return try currentStreamFormat(unit: unit, scope: kAudioUnitScope_Input, bus: 0)
        } catch {
            guard preferred.mChannelsPerFrame == 2 else { throw error }
            // VoiceProcessingIO 在部分设备/模式下输入不支持双声道，这里回退到单声道保证可用。
            var fallback = preferred
            fallback.mChannelsPerFrame = 1
            fallback.mBytesPerFrame = (fallback.mBitsPerChannel / 8) * fallback.mChannelsPerFrame
            fallback.mBytesPerPacket = fallback.mBytesPerFrame * fallback.mFramesPerPacket
            try setStreamFormat(unit: unit, asbd: &fallback)
            return try currentStreamFormat(unit: unit, scope: kAudioUnitScope_Input, bus: 0)
        }
    }

    private func setStreamFormat(unit: AudioUnit, asbd: inout AudioStreamBasicDescription) throws {
        try Self.check(
            AudioUnitSetProperty(
                unit,
                kAudioUnitProperty_StreamFormat,
                kAudioUnitScope_Output,
                1,
                &asbd,
                UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            )
        )
        try Self.check(
            AudioUnitSetProperty(
                unit,
                kAudioUnitProperty_StreamFormat,
                kAudioUnitScope_Input,
                0,
                &asbd,
                UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            )
        )
    }

    private func currentStreamFormat(unit: AudioUnit,
                                     scope: AudioUnitScope,
                                     bus: AudioUnitElement) throws -> AudioStreamBasicDescription {
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try Self.check(
            AudioUnitGetProperty(
                unit,
                kAudioUnitProperty_StreamFormat,
                scope,
                bus,
                &asbd,
                &size
            )
        )
        return asbd
    }
}
