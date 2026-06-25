import Foundation
import TmkTranslationSDK

enum OneToOneChannelAudioPushDestination {
    case interleaved(channelCount: Int)
    case speaker(TmkSpeakerChannel)
}

struct OneToOneChannelAudioPushPlan {
    let data: Data
    let destination: OneToOneChannelAudioPushDestination
}

protocol OneToOneChannelModeConfiguration {
    var audioMode: TmkDialogConversationAudioMode { get }
    var pcmChannels: Int { get }
    var speechStartMetadataChannelsForCurrentVADSource: [UInt8] { get }
    var fillsMissingFileAudioWithSilence: Bool { get }

    func makeInputAudioPushPlan(fileData: Data, rightMicData: Data) -> [OneToOneChannelAudioPushPlan]
}

extension OneToOneChannelModeConfiguration {
    var fillsMissingFileAudioWithSilence: Bool {
        audioMode == .standard
    }

    var speechStartMetadataChannelsForCurrentVADSource: [UInt8] {
        // 当前 Demo 的 VAD 只来自右侧麦克风，不能复用一次 speechStart 同时触发左右两路。
        [OneToOneChannelModeConstants.rightMicMetadataChannel]
    }
}

enum OneToOneChannelModeConfigurationFactory {
    static func make(mode: TmkDialogConversationAudioMode) -> OneToOneChannelModeConfiguration {
        switch mode {
        case .standard:
            return OneToOneStandardChannelModeConfiguration()
        case .lowLatency:
            return OneToOneLowLatencyChannelModeConfiguration()
        }
    }
}

enum OneToOneSpeechMetadataRouting {
    static func channelsForCurrentVADSource(_ audioMode: TmkDialogConversationAudioMode) -> [UInt8] {
        OneToOneChannelModeConfigurationFactory
            .make(mode: audioMode)
            .speechStartMetadataChannelsForCurrentVADSource
    }

    static func channelForLeftFileLoop() -> UInt8 {
        OneToOneChannelModeConstants.leftFileMetadataChannel
    }
}

struct OneToOneLocalAudioLoopChunk {
    let data: Data
    let startsNewCycle: Bool
}

struct OneToOneLocalAudioLoopBuffer {
    static let defaultRestartDelay: TimeInterval = 3

    private let pcmData: Data?
    private let restartDelay: TimeInterval
    private var offset = 0
    private var loopResumeAt: TimeInterval?

    init(pcmData: Data?, restartDelay: TimeInterval = Self.defaultRestartDelay) {
        self.pcmData = pcmData
        self.restartDelay = restartDelay
    }

    mutating func reset() {
        offset = 0
        loopResumeAt = nil
    }

    mutating func nextChunk(expectedLength: Int, now: TimeInterval = CFAbsoluteTimeGetCurrent()) -> Data {
        nextLoopChunk(expectedLength: expectedLength, now: now).data
    }

    mutating func nextLoopChunk(expectedLength: Int, now: TimeInterval = CFAbsoluteTimeGetCurrent()) -> OneToOneLocalAudioLoopChunk {
        guard expectedLength > 0 else {
            return OneToOneLocalAudioLoopChunk(data: Data(), startsNewCycle: false)
        }
        guard let pcmData, pcmData.isEmpty == false else {
            return OneToOneLocalAudioLoopChunk(data: Data(repeating: 0, count: expectedLength),
                                               startsNewCycle: false)
        }
        if let resumeAt = loopResumeAt {
            guard now >= resumeAt else {
                return OneToOneLocalAudioLoopChunk(data: Data(repeating: 0, count: expectedLength),
                                                   startsNewCycle: false)
            }
            loopResumeAt = nil
            offset = 0
        }
        let startsNewCycle = offset == 0
        var slice = Data(capacity: expectedLength)
        var remain = expectedLength
        while remain > 0 {
            guard offset < pcmData.count else {
                loopResumeAt = now + restartDelay
                break
            }
            let available = min(remain, pcmData.count - offset)
            guard available > 0 else { break }
            slice.append(pcmData.subdata(in: offset..<(offset + available)))
            offset += available
            remain -= available
            if offset >= pcmData.count {
                loopResumeAt = now + restartDelay
                break
            }
        }
        if slice.count < expectedLength {
            slice.append(Data(repeating: 0, count: expectedLength - slice.count))
        }
        return OneToOneLocalAudioLoopChunk(data: slice,
                                           startsNewCycle: startsNewCycle && slice.isEmpty == false)
    }
}

private enum OneToOneChannelModeConstants {
    static let leftFileMetadataChannel: UInt8 = 1
    static let rightMicMetadataChannel: UInt8 = 2
}

enum OneToOneTranslatedAudioPlaybackSelector {
    static func selectPlaybackData(data: Data,
                                   channelCount: Int,
                                   playbackMode: OneToOnePlaybackMode,
                                   audioRoute: TmkTranslatedAudioRoute?,
                                   sourceLane: OneToOneRowViewData.Lane,
                                   extraData: [String: Any]) -> Data? {
        guard data.isEmpty == false else { return nil }
        switch audioRoute {
        case .stereo:
            return stereoPlaybackData(data: data,
                                      playbackMode: playbackMode,
                                      extraData: extraData)
        case .left:
            return playbackMode == .left ? data : nil
        case .right:
            return playbackMode == .right ? data : nil
        case .none:
            return legacyPlaybackData(data: data,
                                      channelCount: channelCount,
                                      playbackMode: playbackMode,
                                      sourceLane: sourceLane)
        }
    }

    private static func stereoPlaybackData(data: Data,
                                           playbackMode: OneToOnePlaybackMode,
                                           extraData _: [String: Any]) -> Data? {
        guard let split = TmkTranslationPCMTools.splitStereoInterleaved16LE(data) else {
            return data
        }
        return playbackMode == .left ? split.left : split.right
    }

    private static func legacyPlaybackData(data: Data,
                                           channelCount: Int,
                                           playbackMode: OneToOnePlaybackMode,
                                           sourceLane: OneToOneRowViewData.Lane) -> Data? {
        if playbackMode == .left, sourceLane != .left { return nil }
        if playbackMode == .right, sourceLane != .right { return nil }
        if channelCount == 2, let split = TmkTranslationPCMTools.splitStereoInterleaved16LE(data) {
            return sourceLane == .left ? split.left : split.right
        }
        return data
    }
}
