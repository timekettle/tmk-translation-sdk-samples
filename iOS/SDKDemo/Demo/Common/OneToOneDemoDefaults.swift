//
//  OneToOneDemoDefaults.swift
//  TmkTranslationSDKDemo
//
//  Created by XiongJinhui on 2026/8/18.
//

import Foundation
import TmkTranslationSDK

/// 一对一 Demo 共用的默认配置。
///
/// 这里只保存配置值，不持有 Room、Channel、音频或页面状态；ConcurrentOneToOne 通过它
/// 使用与现有在线/离线一对一页面一致的初始参数，避免两套页面逐渐漂移。
enum OneToOneDemoDefaults {
    static let sampleRate = 16_000
    static let channelCount = 2

    struct OnlineProfile {
        let leftSpeaker: TmkSpeakerGender
        let rightSpeaker: TmkSpeakerGender
        let translateEngine: TmkOnlineTranslateEngine
        let recognizeEngine: TmkOnlineRecognizeEngine
        let translateMode: TmkTranslateDeliveryMode
        let roomScenario: TmkRoomScenario
        let audioMode: TmkDialogConversationAudioMode
    }

    struct OfflineProfile {
        let leftSpeaker: TmkSpeakerGender
        let rightSpeaker: TmkSpeakerGender
        let translateMode: TmkTranslateDeliveryMode
        let roomScenario: TmkRoomScenario
        let audioMode: TmkChannelAudioMode
    }

    // 与 iOS 在线一对一页面的初始状态保持一致。
    static let online = OnlineProfile(
        leftSpeaker: .male,
        rightSpeaker: .female,
        translateEngine: .fast,
        recognizeEngine: .default,
        translateMode: .default,
        roomScenario: .toSpeech,
        audioMode: .standard
    )

    // `.standard` 与 Android 离线配置的 `STEREO` 等价，均输出混合双声道。
    static let offline = OfflineProfile(
        leftSpeaker: .male,
        rightSpeaker: .female,
        translateMode: .partial,
        roomScenario: .toSpeech,
        audioMode: .standard
    )

    /// Concurrent 使用的显式别名，避免未来修改普通页面默认值时破坏双端契约。
    static let concurrentOnline = online
    static let concurrentOffline = offline

    static func offlineModelRootDirectory() -> String {
        (FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("tmkOfflineModel")
            .path
    }
}
