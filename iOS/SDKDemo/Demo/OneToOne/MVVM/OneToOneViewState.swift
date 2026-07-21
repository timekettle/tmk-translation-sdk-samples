import Foundation
import TmkTranslationSDK

enum OneToOnePlaybackMode: String, CaseIterable, Equatable {
    case left
    case right

    var title: String {
        switch self {
        case .left: return "左声道翻译"
        case .right: return "右声道翻译"
        }
    }
}

enum OneToOneScenarioOption: CaseIterable, Equatable {
    case toSpeech
    case recognize
    case toText

    static let defaultOption: OneToOneScenarioOption = .toSpeech

    var title: String {
        switch self {
        case .toSpeech:
            return "语音到语音"
        case .recognize:
            return "单识别"
        case .toText:
            return "语音到文本"
        }
    }

    var roomScenario: TmkRoomScenario {
        switch self {
        case .toSpeech:
            return .toSpeech
        case .recognize:
            return .recognize
        case .toText:
            return .toText
        }
    }
}

struct OneToOneRowViewData: Equatable {
    enum Lane: String {
        case left
        case right
    }

    var sessionId: Int
    let bubbleId: String
    let lane: Lane
    var sourceLangCode: String
    var targetLangCode: String
    var sourceText: String
    var translatedText: String
    /// 源语言按 session 切分的展示片段（用于按 session_id 着色）。
    var sourceSegments: [DemoConversationDisplaySegment] = []
    /// 目标语言按 session 切分的展示片段（用于按 session_id 着色）。
    var translatedSegments: [DemoConversationDisplaySegment] = []
    /// 是否已收到服务端 bubble_end 信号，仅影响展示态，不阻止内容更新。
    var isBubbleEnded: Bool = false
}

struct OneToOneViewState: Equatable {
    var statusText: String = "初始化中..."
    var sourceLanguage: String = "zh-CN"
    var targetLanguage: String = "en-US"
    var translateEngine: TmkOnlineTranslateEngine = .fast
    var scenarioOption: OneToOneScenarioOption = .defaultOption
    var canStartListening: Bool = false
    var canStopListening: Bool = false
    var canSharePCM: Bool = false
    var isCaptureEnabled: Bool = false

    var rows: [OneToOneRowViewData] = []
    var currentRoomNo: String = "-"
    var currentScenario: String = "listen"
    var currentMode: String = "online"

    var configuredSampleRate: Int = 16_000
    var configuredChannels: Int = 2
    var captureSampleRate: Int = 0
    var captureChannels: Int = 0
    var playbackChannels: Int = 0
    var playbackMode: OneToOnePlaybackMode = .left
    var dialogConversationAudioMode: TmkDialogConversationAudioMode = .standard

    var pcmFileURL: URL?
}

extension TmkDialogConversationAudioMode {
    var oneToOneDemoTitle: String {
        switch self {
        case .standard:
            return "标准模式"
        case .lowLatency:
            return "低延迟模式"
        }
    }
}
