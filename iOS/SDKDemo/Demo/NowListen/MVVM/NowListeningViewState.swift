import Foundation
import TmkTranslationSDK

struct NowListeningRowViewData: Equatable {
    var sessionId: Int
    let bubbleId: String
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
    /// 气泡首条 ASR final 句子的 offset(纳秒);bubbleEnd 后展示。
    var bOffset: Int64? = nil
    /// 气泡时长(纳秒);bubbleEnd 后展示。
    var bDuration: Int64? = nil
}

enum NowListeningScenarioOption: CaseIterable, Equatable {
    case toSpeech
    case recognize
    case toText

    static let defaultOption: NowListeningScenarioOption = .toSpeech

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

struct NowListeningViewState: Equatable {
    var statusText: String = "初始化中..."
    var sourceLanguage: String = "zh-CN"
    var targetLanguage: String = "en-US"
    var translateEngine: TmkOnlineTranslateEngine = .accurate
    var scenarioOption: NowListeningScenarioOption = .defaultOption
    var canStartListening: Bool = false
    var canStopListening: Bool = false
    var canSharePCM: Bool = false
    var isCaptureEnabled: Bool = false

    var rows: [NowListeningRowViewData] = []
    var currentRoomNo: String = "-"
    var currentScenario: String = "listen"
    var currentMode: String = "online"

    var configuredSampleRate: Int = 16_000
    var configuredChannels: Int = 1
    var captureSampleRate: Int = 0
    var captureChannels: Int = 0
    var playbackChannels: Int = 0

    var pcmFileURL: URL?
}
