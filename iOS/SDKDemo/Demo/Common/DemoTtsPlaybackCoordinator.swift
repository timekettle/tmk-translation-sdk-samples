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
        stateLock.lock()
        self.voiceIO = voiceIO
        stateLock.unlock()
    }

    /// 是否处于翻译中，由 VM 在 start/stop 时同步；非活跃期丢弃迟到的音频帧。
    func setActive(_ active: Bool) {
        stateLock.lock()
        isActive = active
        if !active {
            voiceIO?.clearPlaybackBuffer()
        }
        stateLock.unlock()
    }

    /// 切换本机播放音源(左路/右路翻译)。切换时清空播放缓冲，避免残留反声道数据。
    func setPlaybackMode(_ mode: OneToOnePlaybackMode) {
        stateLock.lock()
        let changed = playbackMode != mode
        playbackMode = mode
        if changed {
            voiceIO?.clearPlaybackBuffer()
        }
        stateLock.unlock()
    }

    /// 清空播放缓冲(切换 TTS 来源等场景丢弃残留音频)。
    func clearPlaybackBuffer() {
        stateLock.lock()
        voiceIO?.clearPlaybackBuffer()
        stateLock.unlock()
    }

    /// 接管 onAudioDataReceive 的一帧数据，内部完成守卫与播放。
    func handleAudioData(result: TmkResult<String>, data: Data, channelCount: Int) {
        guard result.data == "translated_audio", !data.isEmpty else { return }

        if let queue = processQueue, let backpressure {
            guard let reservation = backpressure.reserve(bytes: data.count) else { return }
            queue.async { [weak self] in
                autoreleasepool {
                    guard let self else { return }
                    defer { backpressure.complete(reservation) }
                    guard backpressure.isCurrent(reservation) else { return }
                    if self.processAudioData(result: result, data: data, channelCount: channelCount) {
                        self.onPlaybackChannelsChanged?(channelCount)
                    }
                }
            }
        } else {
            if processAudioData(result: result, data: data, channelCount: channelCount) {
                onPlaybackChannelsChanged?(channelCount)
            }
        }
    }

    /// 将 active、播放模式快照、选路和最终入队放在同一锁内，防止后台 PCM 在 stop/切路清空后重新写入旧帧。
    @discardableResult
    private func processAudioData(result: TmkResult<String>, data: Data, channelCount: Int) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard isActive, let voiceIO else { return false }
        switch scene {
        case .listen:
            if let target = targetLanguageProvider?(), !target.isEmpty {
                guard result.dstCode.lowercased().hasPrefix(target.lowercased()) else { return false }
            }
            voiceIO.enqueuePlaybackPCM(data)
            return true
        case .oneToOne:
            let route = audioRoute(from: result)
            let lane = resolveSourceLane(result: result,
                                         audioRoute: route,
                                         playbackMode: playbackMode)
            guard let output = OneToOneTranslatedAudioPlaybackSelector.selectPlaybackData(
                data: data,
                channelCount: channelCount,
                playbackMode: playbackMode,
                audioRoute: route,
                sourceLane: lane,
                extraData: result.extraData
            ) else { return false }
            voiceIO.enqueuePlaybackPCM(output)
            return true
        }
    }

    private func resolveSourceLane(result: TmkResult<String>,
                                   audioRoute: TmkTranslatedAudioRoute?,
                                   playbackMode: OneToOnePlaybackMode) -> OneToOneRowViewData.Lane {
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
        return playbackMode == .left ? .left : .right
    }

    private func audioRoute(from result: TmkResult<String>) -> TmkTranslatedAudioRoute? {
        let routeValue = result.extraData["audio_route"]
        if let route = routeValue as? TmkTranslatedAudioRoute { return route }
        if let route = routeValue as? String { return TmkTranslatedAudioRoute(rawValue: route) }
        return nil
    }

}
