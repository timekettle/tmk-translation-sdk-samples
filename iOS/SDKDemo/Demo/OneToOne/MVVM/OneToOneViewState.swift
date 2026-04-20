import Foundation

enum OneToOnePlaybackMode: String, CaseIterable, Equatable {
    case left
    case right

    var title: String {
        switch self {
        case .left: return "目标语言翻译"
        case .right: return "源语言翻译"
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
}

struct OneToOneViewState: Equatable {
    var statusText: String = "初始化中..."
    var sourceLanguage: String = "zh-CN"
    var targetLanguage: String = "en-US"
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

    var pcmFileURL: URL?
}
