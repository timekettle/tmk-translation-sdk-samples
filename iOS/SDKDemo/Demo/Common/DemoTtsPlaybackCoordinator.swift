//
//  DemoTtsPlaybackCoordinator.swift
//  TmkTranslationSDKDemo
//
//  Created by XiongJinhui on 2026/8/20.
//

import Foundation
import TmkTranslationSDK

/// TTS 播放场景。listen=收听(单路直接播放)，oneToOne=一对一(按播放音源/通道模式选路)。
enum DemoTtsScene {
    case listen
    case oneToOne
}

/// 统一的下行 TTS 播放封装，接管 TmkTranslationListener.onAudioDataReceive 的全部音频数据。
///
/// 在类内部消化「守卫 → 选路 → 播放」：
/// - listen：直接 enqueuePlaybackPCM；可选按目标语言 code 前缀过滤。
/// - oneToOne：解析 audio_route + sourceLane，经 OneToOneTranslatedAudioPlaybackSelector
///   按播放音源选路(标准=立体声拆一路，低延迟=左右单路帧按音源过滤)。
///
/// 各 ViewModel 的 onAudioDataReceive 只需一行 handleAudioData 调用；start/stop 时同步 setActive，
/// 切换播放音源时调用 setPlaybackMode。
final class DemoTtsPlaybackCoordinator {
    private let scene: DemoTtsScene
    /// listen 场景的目标语言 code 提供者(运行时可变)；非空时按 dstCode 前缀过滤。返回空串/ nil 表示不过滤。
    private let targetLanguageProvider: (() -> String?)?
    private let processQueue: DispatchQueue?
    private let backpressure: DemoAudioFrameBackpressure?
    /// 可选的一对一 sourceLane 兜底解析器；返回 nil 表示走默认(sourceLane + 播放音源兜底)。
    /// 用于对齐各 VM 的 legacy 兼容差异(在线一对一 uid→lane、离线一对一 channel 字段)。
    private let sourceLaneResolver: ((TmkResult<String>, TmkTranslatedAudioRoute?) -> OneToOneRowViewData.Lane?)?
    /// 可选：收到一帧时上报实际播放声道数(用于 UI 展示，与 Android 对齐)。
    private let onPlaybackChannelsChanged: ((Int) -> Void)?

    private weak var voiceIO: TmkVoiceProcessingIO?
    private let stateLock = NSLock()
    private var isActive = false
    private var playbackMode: OneToOnePlaybackMode = .left

    init(scene: DemoTtsScene,
         targetLanguageProvider: (() -> String?)? = nil,
         processQueue: DispatchQueue? = nil,
         backpressure: DemoAudioFrameBackpressure? = nil,
         sourceLaneResolver: ((TmkResult<String>, TmkTranslatedAudioRoute?) -> OneToOneRowViewData.Lane?)? = nil,
         onPlaybackChannelsChanged: ((Int) -> Void)? = nil) {
        self.scene = scene
        self.targetLanguageProvider = targetLanguageProvider
        self.processQueue = processQueue
        self.backpressure = backpressure
        self.sourceLaneResolver = sourceLaneResolver
        self.onPlaybackChannelsChanged = onPlaybackChannelsChanged
    }

    /// 绑定当前会话的播放 IO(VM 创建 TmkVoiceProcessingIO 后调用)。
    func attach(voiceIO: TmkVoiceProcessingIO?) {
        self.voiceIO = voiceIO
    }

    /// 是否处于翻译中，由 VM 在 start/stop 时同步；非活跃期丢弃迟到的音频帧。
    func setActive(_ active: Bool) {
        stateLock.lock()
        isActive = active
        stateLock.unlock()
        if !active {
            voiceIO?.clearPlaybackBuffer()
        }
    }

    /// 切换本机播放音源(左路/右路翻译)。切换时清空播放缓冲，避免残留反声道数据。
    func setPlaybackMode(_ mode: OneToOnePlaybackMode) {
        stateLock.lock()
        let changed = playbackMode != mode
        playbackMode = mode
        stateLock.unlock()
        if changed {
            voiceIO?.clearPlaybackBuffer()
        }
    }

    /// 清空播放缓冲(切换 TTS 来源等场景丢弃残留音频)。
    func clearPlaybackBuffer() {
        voiceIO?.clearPlaybackBuffer()
    }

    /// 接管 onAudioDataReceive 的一帧数据，内部完成守卫与播放。
    func handleAudioData(result: TmkResult<String>, data: Data, channelCount: Int) {
        guard result.data == "translated_audio", !data.isEmpty else { return }
        guard currentActive() else { return }
        onPlaybackChannelsChanged?(channelCount)

        if let queue = processQueue, let backpressure {
            guard let reservation = backpressure.reserve(bytes: data.count) else { return }
            queue.async { [weak self] in
                autoreleasepool {
                    guard let self else { return }
                    defer { backpressure.complete(reservation) }
                    guard backpressure.isCurrent(reservation) else { return }
                    guard self.currentActive() else { return }
                    self.processAudioData(result: result, data: data, channelCount: channelCount)
                }
            }
        } else {
            processAudioData(result: result, data: data, channelCount: channelCount)
        }
    }

    private func processAudioData(result: TmkResult<String>, data: Data, channelCount: Int) {
        switch scene {
        case .listen:
            if let target = targetLanguageProvider?(), !target.isEmpty {
                guard result.dstCode.lowercased().hasPrefix(target.lowercased()) else { return }
            }
            voiceIO?.enqueuePlaybackPCM(data)
        case .oneToOne:
            let route = audioRoute(from: result)
            let lane = resolveSourceLane(result: result, audioRoute: route)
            guard let output = OneToOneTranslatedAudioPlaybackSelector.selectPlaybackData(
                data: data,
                channelCount: channelCount,
                playbackMode: currentPlaybackMode(),
                audioRoute: route,
                sourceLane: lane,
                extraData: result.extraData
            ) else { return }
            voiceIO?.enqueuePlaybackPCM(output)
        }
    }

    private func resolveSourceLane(result: TmkResult<String>, audioRoute: TmkTranslatedAudioRoute?) -> OneToOneRowViewData.Lane {
        // SDK 显式给出的原始说话侧(speaker_channel)优先级最高，其次才允许各 VM 的 legacy 兜底(uid→lane / channel 字段)。
        if let lane = OneToOneTranslatedAudioSourceRouting.sourceLane(
            audioRoute: audioRoute,
            rawSpeakerChannel: result.extraData["speaker_channel"]
        ) {
            return lane
        }
        if let lane = sourceLaneResolver?(result, audioRoute) {
            return lane
        }
        return currentPlaybackMode() == .left ? .left : .right
    }

    private func audioRoute(from result: TmkResult<String>) -> TmkTranslatedAudioRoute? {
        let routeValue = result.extraData["audio_route"]
        if let route = routeValue as? TmkTranslatedAudioRoute { return route }
        if let route = routeValue as? String { return TmkTranslatedAudioRoute(rawValue: route) }
        return nil
    }

    private func currentActive() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return isActive
    }

    private func currentPlaybackMode() -> OneToOnePlaybackMode {
        stateLock.lock()
        defer { stateLock.unlock() }
        return playbackMode
    }
}
