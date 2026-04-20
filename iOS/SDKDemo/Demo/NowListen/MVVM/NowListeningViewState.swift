import Foundation

struct NowListeningRowViewData: Equatable {
    var sessionId: Int
    let bubbleId: String
    var sourceLangCode: String
    var targetLangCode: String
    var sourceText: String
    var translatedText: String
}

struct NowListeningViewState: Equatable {
    var statusText: String = "初始化中..."
    var sourceLanguage: String = "zh-CN"
    var targetLanguage: String = "en-US"
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
