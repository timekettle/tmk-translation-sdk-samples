import AVFoundation
import Flutter
import Foundation
import TmkTranslationSDK

public final class TmkTranslationFlutterPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
    private static let serviceRootURL = URL(string: "https://tmk-translation-test.timekettle.net/")!

    private let settingsStore = TmkSettingsStore()
    private var eventSink: FlutterEventSink?
    private var sessions: [String: BaseSession] = [:]

    public static func register(with registrar: FlutterPluginRegistrar) {
        let instance = TmkTranslationFlutterPlugin()
        let methodChannel = FlutterMethodChannel(
            name: "co.timekettle.translation.flutter/methods",
            binaryMessenger: registrar.messenger()
        )
        let eventChannel = FlutterEventChannel(
            name: "co.timekettle.translation.flutter/events",
            binaryMessenger: registrar.messenger()
        )
        registrar.addMethodCallDelegate(instance, channel: methodChannel)
        eventChannel.setStreamHandler(instance)
    }

    public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        eventSink = events
        return nil
    }

    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        eventSink = nil
        return nil
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "getCurrentSettings":
            result(settingsStore.load().toMap())
        case "initialize":
            handleInitialize(call, result: result)
        case "applySettings":
            handleApplySettings(call, result: result)
        case "verifyAuth":
            TmkTranslationSDK.shared.verifyAuth { verifyResult in
                switch verifyResult {
                case .success:
                    result(true)
                case .failure:
                    result(false)
                }
            }
        case "getSupportedLanguages":
            handleGetSupportedLanguages(call, result: result)
        case "getRuntimeStatus":
            handleGetRuntimeStatus(result: result)
        case "exportDiagnosisLogs":
            result(TmkTranslationSDK.shared.getDiagnosisDirectoryURL()?.path)
        case "createSession":
            let config = SessionConfig(map: call.arguments as? [String: Any] ?? [:])
            let sessionId = UUID().uuidString
            sessions[sessionId] = makeSession(sessionId: sessionId, config: config)
            result(sessionId)
        case "getOfflineModelStatus":
            guard let session = lookupSession(call.arguments, result: result) else { return }
            result(session.getOfflineModelStatus())
        case "downloadOfflineModels":
            guard let session = lookupSession(call.arguments, result: result) else { return }
            session.downloadOfflineModels()
            result(nil)
        case "cancelOfflineDownload":
            guard let session = lookupSession(call.arguments, result: result) else { return }
            session.cancelOfflineDownload()
            result(nil)
        case "startSession":
            guard let session = lookupSession(call.arguments, result: result) else { return }
            session.start()
            result(nil)
        case "stopSession":
            guard let session = lookupSession(call.arguments, result: result) else { return }
            session.stop()
            result(nil)
        case "disposeSession":
            guard let session = lookupSession(call.arguments, result: result) else { return }
            session.dispose()
            sessions.removeValue(forKey: session.sessionId)
            result(nil)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func handleInitialize(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        do {
            let arguments = call.arguments as? [String: Any] ?? [:]
            let settings = TmkPluginSettings(map: arguments["settings"] as? [String: Any] ?? [:])
            settingsStore.save(settings)
            try initializeSdk(appId: arguments["appId"] as? String,
                              appSecret: arguments["appSecret"] as? String,
                              settings: settings)
            handleGetRuntimeStatus(result: result)
        } catch {
            result(FlutterError(code: "sdk_init_failed", message: error.localizedDescription, details: nil))
        }
    }

    private func handleApplySettings(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        handleInitialize(call, result: result)
    }

    private func handleGetSupportedLanguages(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let arguments = call.arguments as? [String: Any] ?? [:]
        let sourceValue = arguments["source"] as? String ?? "online"
        let source: TmkSupportedLanguagesSource = sourceValue == "offline" ? .offline : .online
        _ = TmkTranslationSDK.shared.getSupportedLanguages(source: source, uiLocales: ["zh-CN"]) { supportedResult in
            switch supportedResult {
            case .success(let response):
                let items = response.localeOptions.map { option in
                    [
                        "code": option.code,
                        "familyCode": option.code.split(separator: "-").first.map(String.init) ?? option.code,
                        "title": option.uiLang.isEmpty ? option.nativeLang : option.uiLang
                    ]
                }
                result(items)
            case .failure(let error):
                result(FlutterError(code: "supported_languages_failed",
                                    message: error.localizedDescription,
                                    details: nil))
            }
        }
    }

    private func handleGetRuntimeStatus(result: @escaping FlutterResult) {
        TmkTranslationSDK.shared.verifyAuth { verifyResult in
            switch verifyResult {
            case .success:
                let offlineSupported = TmkTranslationSDK.shared.isOfflineTranslationSupported()
                result([
                    "onlineEngineStatus": [
                        "kind": "available",
                        "summary": "可用",
                        "detail": "鉴权成功"
                    ],
                    "offlineEngineStatus": [
                        "kind": offlineSupported ? "available" : "unavailable",
                        "summary": offlineSupported ? "可用" : "不可用",
                        "detail": offlineSupported ? "离线翻译已开通" : "当前账号未开通离线翻译"
                    ],
                    "authInfo": [
                        "tokenSummary": "有效",
                        "tokenDetail": "鉴权成功，可继续创建房间或通道",
                        "autoRefreshSummary": "暂无数据",
                        "autoRefreshDetail": "当前版本未暴露详细刷新信息"
                    ],
                    "versionText": Self.makeVersionText()
                ])
            case .failure(let error):
                let detail = error.localizedDescription
                result([
                    "onlineEngineStatus": [
                        "kind": "unavailable",
                        "summary": "不可用",
                        "detail": detail
                    ],
                    "offlineEngineStatus": [
                        "kind": "unavailable",
                        "summary": "不可用",
                        "detail": "依赖鉴权结果"
                    ],
                    "authInfo": [
                        "tokenSummary": "不可用",
                        "tokenDetail": detail,
                        "autoRefreshSummary": "暂无数据",
                        "autoRefreshDetail": "当前版本未暴露详细刷新信息"
                    ],
                    "versionText": Self.makeVersionText()
                ])
            }
        }
    }

    private func initializeSdk(appId: String?, appSecret: String?, settings: TmkPluginSettings) throws {
        let credentials = try resolveCredentials(appId: appId, appSecret: appSecret)
        let globalConfig = TmkTranslationGlobalConfig.Builder()
            .setAuth(appId: credentials.appId, secret: credentials.appSecret)
            .setOnlineAuthContext(tenantId: "timekettle")
            .setLogEnabled(settings.consoleLogEnabled)
            .setNetworkBaseURL(Self.sdkNetworkBaseURL())
            .setDiagnosisEnabled(settings.diagnosisEnabled)
            .build()
        TmkTranslationSDK.shared.destroy()
        TmkTranslationSDK.shared.sdkInit(globalConfig)
    }

    private func resolveCredentials(appId: String?, appSecret: String?) throws -> (appId: String, appSecret: String) {
        let resolvedAppId = appId?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            ?? (Bundle.main.object(forInfoDictionaryKey: "TMKSampleAppID") as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        let resolvedAppSecret = appSecret?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            ?? (Bundle.main.object(forInfoDictionaryKey: "TMKSampleAppSecret") as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        guard let resolvedAppId else {
            throw NSError(domain: "tmk_translation_flutter",
                          code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Missing TMKSampleAppID. Configure it in Info.plist/xcconfig or pass it to initialize()."])
        }
        guard let resolvedAppSecret else {
            throw NSError(domain: "tmk_translation_flutter",
                          code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Missing TMKSampleAppSecret. Configure it in Info.plist/xcconfig or pass it to initialize()."])
        }
        return (resolvedAppId, resolvedAppSecret)
    }

    private func lookupSession(_ arguments: Any?, result: FlutterResult) -> BaseSession? {
        let payload = arguments as? [String: Any] ?? [:]
        let sessionId = payload["sessionId"] as? String
        guard let sessionId, let session = sessions[sessionId] else {
            result(FlutterError(code: "missing_session", message: "Session not found", details: nil))
            return nil
        }
        return session
    }

    private func makeSession(sessionId: String, config: SessionConfig) -> BaseSession {
        if config.mode == .online, config.scenario == .listen {
            return OnlineListenSession(sessionId: sessionId, config: config, emitter: emit)
        }
        if config.mode == .online, config.scenario == .oneToOne {
            return OnlineOneToOneSession(sessionId: sessionId, config: config, emitter: emit)
        }
        if config.mode == .offline, config.scenario == .listen {
            return OfflineListenSession(sessionId: sessionId, config: config, emitter: emit)
        }
        return OfflineOneToOneSession(sessionId: sessionId, config: config, emitter: emit)
    }

    private func emit(kind: String, sessionId: String?, payload: [String: Any?]) {
        var event: [String: Any?] = ["kind": kind]
        if let sessionId {
            event["sessionId"] = sessionId
        }
        payload.forEach { event[$0.key] = $0.value }
        DispatchQueue.main.async {
            self.eventSink?(event)
        }
    }

    private static func makeVersionText() -> String {
        let version = Bundle(for: TmkTranslationSDK.self)
            .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return "TmkTranslationSDK v\(version ?? "1.0.0")"
    }

    private static func sdkNetworkBaseURL() -> URL {
        serviceRootURL.appendingPathComponent("apis")
    }
}

private enum SessionMode: String {
    case online
    case offline
}

private enum SessionScenario: String {
    case listen = "listen"
    case oneToOne = "one_to_one"
}

private struct SessionConfig {
    let scenario: SessionScenario
    let mode: SessionMode
    let sourceLanguage: String
    let targetLanguage: String
    let useFixedAudio: Bool

    init(map: [String: Any]) {
        scenario = SessionScenario(rawValue: map["scenario"] as? String ?? "listen") ?? .listen
        mode = SessionMode(rawValue: map["mode"] as? String ?? "online") ?? .online
        sourceLanguage = map["sourceLanguage"] as? String ?? "zh-CN"
        targetLanguage = map["targetLanguage"] as? String ?? "en-US"
        useFixedAudio = map["useFixedAudio"] as? Bool ?? true
    }
}

private class BaseSession: NSObject {
    let sessionId: String
    let config: SessionConfig
    let emitter: (String, String?, [String: Any?]) -> Void

    init(sessionId: String,
         config: SessionConfig,
         emitter: @escaping (String, String?, [String: Any?]) -> Void) {
        self.sessionId = sessionId
        self.config = config
        self.emitter = emitter
        super.init()
    }

    func start() {}
    func stop() {}
    func dispose() { stop() }
    func downloadOfflineModels() {
        emitError(code: "unsupported_operation", message: "当前会话不支持离线模型下载")
    }
    func cancelOfflineDownload() {}

    func getOfflineModelStatus() -> [String: Any] {
        [
            "isReady": true,
            "isSupported": true,
            "summary": "在线模式",
            "detail": "在线模式不依赖本地模型"
        ]
    }

    func emitSessionState(statusText: String,
                          isStarted: Bool? = nil,
                          isStarting: Bool? = nil,
                          isModelReady: Bool? = nil) {
        emitter("session_state", sessionId, [
            "statusText": statusText,
            "isStarted": isStarted,
            "isStarting": isStarting,
            "isModelReady": isModelReady
        ])
    }

    func emitBubble(bubbleId: String,
                    sourceLangCode: String,
                    targetLangCode: String,
                    isFinal: Bool,
                    sourceText: String? = nil,
                    translatedText: String? = nil,
                    channel: String? = nil) {
        emitter("bubble", sessionId, [
            "bubbleId": bubbleId,
            "sourceLangCode": sourceLangCode,
            "targetLangCode": targetLangCode,
            "isFinal": isFinal,
            "sourceText": sourceText,
            "translatedText": translatedText,
            "channel": channel
        ])
    }

    func emitDownload(message: String,
                      progress: Double? = nil,
                      stage: String = "downloading",
                      isCompleted: Bool = false) {
        emitter("download", sessionId, [
            "message": message,
            "progress": progress,
            "stage": stage,
            "isCompleted": isCompleted
        ])
    }

    func emitLog(_ message: String, level: String = "info") {
        emitter("log", sessionId, ["message": message, "level": level])
    }

    func emitError(code: String, message: String) {
        emitter("error", sessionId, ["code": code, "message": message])
    }

    func bubbleId(from result: TmkResult<String>) -> String {
        if let extraBubbleId = result.extraData["bubbleId"] as? String, extraBubbleId.isEmpty == false {
            return extraBubbleId
        }
        if let serialId = result.extraData["serialId"] as? String, serialId.isEmpty == false {
            return serialId
        }
        if let bubbleId = result.extraData["msgId"] as? String, bubbleId.isEmpty == false {
            return bubbleId
        }
        return String(result.sessionId)
    }
}

private final class OnlineListenSession: BaseSession, TmkTranslationListener {
    private var room: TmkTranslationRoom?
    private var channel: TmkTranslationChannel?
    private var voiceIO: TmkVoiceProcessingIO?

    override func start() {
        emitSessionState(statusText: "开始鉴权...", isStarting: true)
        TmkTranslationSDK.shared.verifyAuth { [weak self] verifyResult in
            guard let self else { return }
            switch verifyResult {
            case .success:
                self.createRoomAndChannel()
            case .failure(let error):
                self.emitError(code: "verify_auth_failed", message: error.localizedDescription)
                self.emitSessionState(statusText: "鉴权失败", isStarting: false)
            }
        }
    }

    override func stop() {
        let closingRoom = room
        voiceIO?.stop()
        voiceIO = nil
        channel?.stop()
        channel = nil
        room = nil
        closingRoom.flatMap(closeRoom)
        emitSessionState(statusText: "翻译已停止", isStarted: false, isStarting: false)
    }

    private func createRoomAndChannel() {
        room = TmkTranslationSDK.shared.createTmkTranslationRoom(
            sourceLang: config.sourceLanguage,
            targetLang: config.targetLanguage,
            scenario: .toSpeech,
            channelScenario: .listen
        ) { [weak self] roomResult in
            guard let self else { return }
            switch roomResult {
            case .success(let room):
                let channelConfig = TmkTranslationChannelConfig.Builder()
                    .setRoom(room)
                    .setScenario(.listen)
                    .setMode(.online)
                    .setSourceLang(self.config.sourceLanguage)
                    .setTargetLang(self.config.targetLanguage)
                    .setPCMSampleRate(16_000)
                    .setPCMChannels(1)
                    .build()
                TmkTranslationSDK.shared.createTranslationChannel(channelConfig, listener: self) { channelResult in
                    switch channelResult {
                    case .success(let createdChannel):
                        self.channel = createdChannel
                        self.emitSessionState(statusText: "通道已就绪", isStarted: true, isStarting: false)
                        self.startListening()
                    case .failure(let error):
                        self.emitError(code: "create_channel_failed", message: error.localizedDescription)
                        self.emitSessionState(statusText: "创建通道失败", isStarting: false)
                    }
                }
            case .failure(let error):
                self.emitError(code: "create_room_failed", message: error.localizedDescription)
                self.emitSessionState(statusText: "创建房间失败", isStarting: false)
            }
        }
    }

    private func startListening() {
        if voiceIO == nil {
            voiceIO = TmkVoiceProcessingIO(config: TmkVPConfig(sampleRate: 16_000,
                                                               channels: 1,
                                                               bitsPerChannel: 16,
                                                               framesPerBuffer: 1024))
        }
        guard let voiceIO else { return }
        do {
            try TmkVoiceProcessingIO.configureAudioSession(sampleRate: 16000,
                                                           framesPerBuffer: 1024,
                                                           mode: .voiceChat,
                                                           useSpeaker: true)
        } catch {
            emitError(code: "audio_session_failed", message: error.localizedDescription)
            return
        }
        voiceIO.onInputPCM = { [weak self, weak channel] data, format, _ in
            _ = format
            self?.emitSessionState(statusText: "翻译中...", isStarted: true, isStarting: false)
            channel?.pushStreamAudioData(data, channelCount: 1, extraChunk: nil)
        }
        voiceIO.requestRecordPermission { [weak self] granted in
            guard let self else { return }
            guard granted else {
                self.emitError(code: "record_permission_denied", message: "麦克风权限未授权")
                return
            }
            do {
                try voiceIO.start()
            } catch {
                self.emitError(code: "start_listening_failed", message: error.localizedDescription)
            }
        }
    }

    func onRecognized(from engine: AbstractChannelEngine, result: TmkResult<String>, isFinal: Bool) {
        _ = engine
        emitBubble(bubbleId: bubbleId(from: result),
                   sourceLangCode: result.srcCode,
                   targetLangCode: result.dstCode,
                   isFinal: isFinal,
                   sourceText: result.data)
    }

    func onTranslate(from engine: AbstractChannelEngine, result: TmkResult<String>, isFinal: Bool) {
        _ = engine
        emitBubble(bubbleId: bubbleId(from: result),
                   sourceLangCode: result.srcCode,
                   targetLangCode: result.dstCode,
                   isFinal: isFinal,
                   translatedText: result.data)
    }

    func onAudioDataReceive(from engine: AbstractChannelEngine, result: TmkResult<String>, data: Data, channelCount: Int) {
        _ = (engine, result, channelCount)
        voiceIO?.enqueuePlaybackPCM(data)
    }

    func onError(_ error: TmkTranslationError) {
        emitError(code: "translation_error", message: error.localizedDescription)
    }

    func onEvent(name: String, args: Any?) {
        _ = args
        emitLog(name)
    }
}

private final class OnlineOneToOneSession: BaseSession, TmkTranslationListener {
    private var room: TmkTranslationRoom?
    private var channel: TmkTranslationChannel?
    private var voiceIO: TmkVoiceProcessingIO?
    private lazy var fixedPCMData: Data? = FixedAudioAssetResolver.fixedPCMData()
    private var fixedPCMOffset = 0

    override func start() {
        emitSessionState(statusText: "开始鉴权...", isStarting: true)
        TmkTranslationSDK.shared.verifyAuth { [weak self] verifyResult in
            guard let self else { return }
            switch verifyResult {
            case .success:
                self.createRoomAndChannel()
            case .failure(let error):
                self.emitError(code: "verify_auth_failed", message: error.localizedDescription)
                self.emitSessionState(statusText: "鉴权失败", isStarting: false)
            }
        }
    }

    override func stop() {
        let closingRoom = room
        voiceIO?.stop()
        voiceIO = nil
        channel?.stop()
        channel = nil
        room = nil
        closingRoom.flatMap(closeRoom)
        fixedPCMOffset = 0
        emitSessionState(statusText: "翻译已停止", isStarted: false, isStarting: false)
    }

    private func createRoomAndChannel() {
        room = TmkTranslationSDK.shared.createTmkTranslationRoom(
            sourceLang: config.sourceLanguage,
            targetLang: config.targetLanguage,
            scenario: .toSpeech,
            channelScenario: .oneToOne
        ) { [weak self] roomResult in
            guard let self else { return }
            switch roomResult {
            case .success(let room):
                let channelConfig = TmkTranslationChannelConfig.Builder()
                    .setRoom(room)
                    .setScenario(.oneToOne)
                    .setMode(.online)
                    .setSourceLang(self.config.sourceLanguage)
                    .setTargetLang(self.config.targetLanguage)
                    .setPCMSampleRate(16_000)
                    .setPCMChannels(2)
                    .build()
                TmkTranslationSDK.shared.createTranslationChannel(channelConfig, listener: self) { channelResult in
                    switch channelResult {
                    case .success(let createdChannel):
                        self.channel = createdChannel
                        self.emitSessionState(statusText: "1v1 通道已就绪", isStarted: true, isStarting: false)
                        self.startListening()
                    case .failure(let error):
                        self.emitError(code: "create_channel_failed", message: error.localizedDescription)
                        self.emitSessionState(statusText: "创建通道失败", isStarting: false)
                    }
                }
            case .failure(let error):
                self.emitError(code: "create_room_failed", message: error.localizedDescription)
                self.emitSessionState(statusText: "创建房间失败", isStarting: false)
            }
        }
    }

    private func startListening() {
        if voiceIO == nil {
            voiceIO = TmkVoiceProcessingIO(config: TmkVPConfig(sampleRate: 16_000,
                                                               channels: 1,
                                                               bitsPerChannel: 16,
                                                               framesPerBuffer: 1024))
        }
        guard let voiceIO else { return }
        do {
            try TmkVoiceProcessingIO.configureAudioSession(sampleRate: 16000,
                                                           framesPerBuffer: 1024,
                                                           mode: .voiceChat,
                                                           useSpeaker: true)
        } catch {
            emitError(code: "audio_session_failed", message: error.localizedDescription)
            return
        }
        voiceIO.onInputPCM = { [weak self, weak channel] data, _, _ in
            guard let self else { return }
            let rightAudio = self.nextFixedAudioChunk(expectedLength: data.count)
            let mixed = TmkTranslationPCMTools.mixStereo16LE(left: rightAudio, right: data) ?? data
            channel?.pushStreamAudioData(mixed, channelCount: 2, extraChunk: nil)
        }
        voiceIO.requestRecordPermission { [weak self] granted in
            guard let self else { return }
            guard granted else {
                self.emitError(code: "record_permission_denied", message: "麦克风权限未授权")
                return
            }
            do {
                try voiceIO.start()
            } catch {
                self.emitError(code: "start_listening_failed", message: error.localizedDescription)
            }
        }
    }

    private func nextFixedAudioChunk(expectedLength: Int) -> Data {
        guard config.useFixedAudio, let fixedPCMData, fixedPCMData.isEmpty == false else {
            return Data(count: expectedLength)
        }
        let end = min(fixedPCMOffset + expectedLength, fixedPCMData.count)
        let chunk = fixedPCMData.subdata(in: fixedPCMOffset..<end)
        fixedPCMOffset = end >= fixedPCMData.count ? 0 : end
        if chunk.count < expectedLength {
            return chunk + Data(count: expectedLength - chunk.count)
        }
        return chunk
    }

    func onRecognized(from engine: AbstractChannelEngine, result: TmkResult<String>, isFinal: Bool) {
        _ = engine
        emitBubble(bubbleId: bubbleId(from: result),
                   sourceLangCode: result.srcCode,
                   targetLangCode: result.dstCode,
                   isFinal: isFinal,
                   sourceText: result.data,
                   channel: result.extraData["channel"] as? String)
    }

    func onTranslate(from engine: AbstractChannelEngine, result: TmkResult<String>, isFinal: Bool) {
        _ = engine
        emitBubble(bubbleId: bubbleId(from: result),
                   sourceLangCode: result.srcCode,
                   targetLangCode: result.dstCode,
                   isFinal: isFinal,
                   translatedText: result.data,
                   channel: result.extraData["channel"] as? String)
    }

    func onAudioDataReceive(from engine: AbstractChannelEngine, result: TmkResult<String>, data: Data, channelCount: Int) {
        _ = (engine, result)
        if channelCount == 2 {
            voiceIO?.enqueuePlaybackPCM(data)
        } else if let stereo = TmkTranslationPCMTools.mixStereo16LE(left: data, right: data) {
            voiceIO?.enqueuePlaybackPCM(stereo)
        } else {
            voiceIO?.enqueuePlaybackPCM(data)
        }
    }

    func onError(_ error: TmkTranslationError) {
        emitError(code: "translation_error", message: error.localizedDescription)
    }

    func onEvent(name: String, args: Any?) {
        _ = args
        emitLog(name)
    }
}

private final class OfflineListenSession: BaseSession, TmkTranslationListener, TmkOfflineModelDownloadListener {
    private var channel: TmkTranslationChannel?
    private var voiceIO: TmkVoiceProcessingIO?
    private let modelRootDirectory: String = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("tmkOfflineModel").path
    }()

    override func getOfflineModelStatus() -> [String: Any] {
        let ready = TmkTranslationSDK.shared.isOfflineModelReady(srcLang: config.sourceLanguage,
                                                                 dstLang: config.targetLanguage,
                                                                 modelRootDirectory: modelRootDirectory,
                                                                 scenario: .listen)
        return [
            "isReady": ready,
            "isSupported": true,
            "summary": ready ? "模型已就绪" : "需要下载模型",
            "detail": ready ? "可直接开始离线旁听" : "当前语言对仍缺少离线模型"
        ]
    }

    override func downloadOfflineModels() {
        emitDownload(message: "准备下载离线模型", progress: 0)
        TmkTranslationSDK.shared.downloadOfflineModels(
            srcLang: config.sourceLanguage,
            dstLang: config.targetLanguage,
            modelRootDirectory: modelRootDirectory,
            scenario: .listen,
            listener: self
        )
    }

    override func cancelOfflineDownload() {
        TmkTranslationSDK.shared.cancelOfflineModelDownload()
    }

    override func start() {
        let ready = TmkTranslationSDK.shared.isOfflineModelReady(srcLang: config.sourceLanguage,
                                                                 dstLang: config.targetLanguage,
                                                                 modelRootDirectory: modelRootDirectory,
                                                                 scenario: .listen)
        guard ready else {
            emitError(code: "offline_models_missing", message: "当前语言对仍缺少离线模型")
            return
        }
        let channelConfig = TmkTranslationChannelConfig.Builder()
            .setMode(.offline)
            .setScenario(.listen)
            .setSourceLang(config.sourceLanguage)
            .setTargetLang(config.targetLanguage)
            .setPCMSampleRate(16_000)
            .setPCMChannels(1)
            .setModelRootDirectory(modelRootDirectory)
            .build()
        TmkTranslationSDK.shared.createTranslationChannel(channelConfig, listener: self) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let createdChannel):
                self.channel = createdChannel
                self.emitSessionState(statusText: "离线通道已就绪", isStarted: true, isStarting: false)
                self.startListening()
            case .failure(let error):
                self.emitError(code: "create_channel_failed", message: error.localizedDescription)
            }
        }
    }

    override func stop() {
        voiceIO?.stop()
        voiceIO = nil
        TmkTranslationSDK.shared.releaseChannel()
        channel = nil
        emitSessionState(statusText: "翻译已停止", isStarted: false, isStarting: false)
    }

    private func startListening() {
        if voiceIO == nil {
            voiceIO = TmkVoiceProcessingIO(config: TmkVPConfig(sampleRate: 16_000,
                                                               channels: 1,
                                                               bitsPerChannel: 16,
                                                               framesPerBuffer: 1024))
        }
        guard let voiceIO else { return }
        do {
            try TmkVoiceProcessingIO.configureAudioSession(sampleRate: 16000,
                                                           framesPerBuffer: 1024,
                                                           mode: .voiceChat,
                                                           useSpeaker: true)
        } catch {
            emitError(code: "audio_session_failed", message: error.localizedDescription)
            return
        }
        voiceIO.onInputPCM = { [weak channel] data, _, _ in
            channel?.pushStreamAudioData(data, channelCount: 1, extraChunk: nil)
        }
        voiceIO.requestRecordPermission { [weak self] granted in
            guard let self else { return }
            guard granted else {
                self.emitError(code: "record_permission_denied", message: "麦克风权限未授权")
                return
            }
            do {
                try voiceIO.start()
            } catch {
                self.emitError(code: "start_listening_failed", message: error.localizedDescription)
            }
        }
    }

    func onRecognized(from engine: AbstractChannelEngine, result: TmkResult<String>, isFinal: Bool) {
        _ = engine
        emitBubble(bubbleId: bubbleId(from: result),
                   sourceLangCode: result.srcCode,
                   targetLangCode: result.dstCode,
                   isFinal: isFinal,
                   sourceText: result.data)
    }

    func onTranslate(from engine: AbstractChannelEngine, result: TmkResult<String>, isFinal: Bool) {
        _ = engine
        emitBubble(bubbleId: bubbleId(from: result),
                   sourceLangCode: result.srcCode,
                   targetLangCode: result.dstCode,
                   isFinal: isFinal,
                   translatedText: result.data)
    }

    func onAudioDataReceive(from engine: AbstractChannelEngine, result: TmkResult<String>, data: Data, channelCount: Int) {
        _ = (engine, result, channelCount)
        voiceIO?.enqueuePlaybackPCM(data)
    }

    func onError(_ error: TmkTranslationError) {
        emitError(code: "translation_error", message: error.localizedDescription)
    }

    func onEvent(name: String, args: Any?) {
        _ = args
        emitLog(name)
    }

    func onOfflineModelEvent(name: String, args: Any?) {
        _ = args
        emitLog(name)
    }

    func onOfflineModelError(_ error: TmkTranslationError) {
        emitError(code: "offline_download_failed", message: error.localizedDescription)
    }

    func onOfflineModelDownloadProgress(fileName: String, index: Int, total: Int, downloaded: Int64, fileTotal: Int64) {
        let progress = fileTotal > 0 ? Double(downloaded) / Double(fileTotal) : nil
        emitDownload(message: "($index/$total) \(fileName)", progress: progress)
    }

    func onOfflineModelUnzipProgress(fileName: String, progress: Double) {
        emitDownload(message: "解压 \(fileName)", progress: progress)
    }

    func onOfflineModelReady() {
        emitDownload(message: "模型下载完成", progress: 1, stage: "completed", isCompleted: true)
        emitSessionState(statusText: "离线模型已就绪", isModelReady: true)
    }

    func onOfflineModelPackageInfosChanged(_ packages: [TmkOfflineModelPackageInfo]) {
        emitLog("offline packages updated: \(packages.count)")
    }
}

private final class OfflineOneToOneSession: BaseSession, TmkTranslationListener, TmkOfflineModelDownloadListener {
    private var channel: TmkTranslationChannel?
    private var voiceIO: TmkVoiceProcessingIO?
    private let modelRootDirectory: String = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("tmkOfflineModel").path
    }()
    private lazy var fixedPCMData: Data? = FixedAudioAssetResolver.fixedPCMData()
    private var fixedPCMOffset = 0

    override func getOfflineModelStatus() -> [String: Any] {
        let forward = TmkTranslationSDK.shared.isOfflineModelReady(srcLang: config.sourceLanguage,
                                                                   dstLang: config.targetLanguage,
                                                                   modelRootDirectory: modelRootDirectory,
                                                                   scenario: .oneToOne)
        let reverse = TmkTranslationSDK.shared.isOfflineModelReady(srcLang: config.targetLanguage,
                                                                   dstLang: config.sourceLanguage,
                                                                   modelRootDirectory: modelRootDirectory,
                                                                   scenario: .oneToOne)
        let ready = forward && reverse
        return [
            "isReady": ready,
            "isSupported": true,
            "summary": ready ? "双向模型已就绪" : "需要下载双向模型",
            "detail": ready ? "可直接开始离线 1v1" : "当前语言对仍缺少双向离线模型"
        ]
    }

    override func downloadOfflineModels() {
        emitDownload(message: "准备下载双向离线模型", progress: 0)
        TmkTranslationSDK.shared.downloadOfflineModels(
            srcLang: config.sourceLanguage,
            dstLang: config.targetLanguage,
            modelRootDirectory: modelRootDirectory,
            scenario: .oneToOne,
            listener: self
        )
    }

    override func cancelOfflineDownload() {
        TmkTranslationSDK.shared.cancelOfflineModelDownload()
    }

    override func start() {
        let forward = TmkTranslationSDK.shared.isOfflineModelReady(srcLang: config.sourceLanguage,
                                                                   dstLang: config.targetLanguage,
                                                                   modelRootDirectory: modelRootDirectory,
                                                                   scenario: .oneToOne)
        let reverse = TmkTranslationSDK.shared.isOfflineModelReady(srcLang: config.targetLanguage,
                                                                   dstLang: config.sourceLanguage,
                                                                   modelRootDirectory: modelRootDirectory,
                                                                   scenario: .oneToOne)
        guard forward && reverse else {
            emitError(code: "offline_models_missing", message: "当前语言对仍缺少双向离线模型")
            return
        }
        let channelConfig = TmkTranslationChannelConfig.Builder()
            .setMode(.offline)
            .setScenario(.oneToOne)
            .setSourceLang(config.sourceLanguage)
            .setTargetLang(config.targetLanguage)
            .setPCMSampleRate(16_000)
            .setPCMChannels(2)
            .setModelRootDirectory(modelRootDirectory)
            .build()
        TmkTranslationSDK.shared.createTranslationChannel(channelConfig, listener: self) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let createdChannel):
                self.channel = createdChannel
                self.emitSessionState(statusText: "离线 1v1 通道已就绪", isStarted: true, isStarting: false)
                self.startListening()
            case .failure(let error):
                self.emitError(code: "create_channel_failed", message: error.localizedDescription)
            }
        }
    }

    override func stop() {
        voiceIO?.stop()
        voiceIO = nil
        TmkTranslationSDK.shared.releaseChannel()
        channel = nil
        fixedPCMOffset = 0
        emitSessionState(statusText: "翻译已停止", isStarted: false, isStarting: false)
    }

    private func startListening() {
        if voiceIO == nil {
            voiceIO = TmkVoiceProcessingIO(config: TmkVPConfig(sampleRate: 16_000,
                                                               channels: 1,
                                                               bitsPerChannel: 16,
                                                               framesPerBuffer: 1024))
        }
        guard let voiceIO else { return }
        do {
            try TmkVoiceProcessingIO.configureAudioSession(sampleRate: 16000,
                                                           framesPerBuffer: 1024,
                                                           mode: .voiceChat,
                                                           useSpeaker: true)
        } catch {
            emitError(code: "audio_session_failed", message: error.localizedDescription)
            return
        }
        voiceIO.onInputPCM = { [weak self, weak channel] data, _, _ in
            guard let self else { return }
            let rightAudio = self.nextFixedAudioChunk(expectedLength: data.count)
            let mixed = TmkTranslationPCMTools.mixStereo16LE(left: rightAudio, right: data) ?? data
            channel?.pushStreamAudioData(mixed, channelCount: 2, extraChunk: nil)
        }
        voiceIO.requestRecordPermission { [weak self] granted in
            guard let self else { return }
            guard granted else {
                self.emitError(code: "record_permission_denied", message: "麦克风权限未授权")
                return
            }
            do {
                try voiceIO.start()
            } catch {
                self.emitError(code: "start_listening_failed", message: error.localizedDescription)
            }
        }
    }

    private func nextFixedAudioChunk(expectedLength: Int) -> Data {
        guard config.useFixedAudio, let fixedPCMData, fixedPCMData.isEmpty == false else {
            return Data(count: expectedLength)
        }
        let end = min(fixedPCMOffset + expectedLength, fixedPCMData.count)
        let chunk = fixedPCMData.subdata(in: fixedPCMOffset..<end)
        fixedPCMOffset = end >= fixedPCMData.count ? 0 : end
        if chunk.count < expectedLength {
            return chunk + Data(count: expectedLength - chunk.count)
        }
        return chunk
    }

    func onRecognized(from engine: AbstractChannelEngine, result: TmkResult<String>, isFinal: Bool) {
        _ = engine
        emitBubble(bubbleId: bubbleId(from: result),
                   sourceLangCode: result.srcCode,
                   targetLangCode: result.dstCode,
                   isFinal: isFinal,
                   sourceText: result.data,
                   channel: result.extraData["channel"] as? String)
    }

    func onTranslate(from engine: AbstractChannelEngine, result: TmkResult<String>, isFinal: Bool) {
        _ = engine
        emitBubble(bubbleId: bubbleId(from: result),
                   sourceLangCode: result.srcCode,
                   targetLangCode: result.dstCode,
                   isFinal: isFinal,
                   translatedText: result.data,
                   channel: result.extraData["channel"] as? String)
    }

    func onAudioDataReceive(from engine: AbstractChannelEngine, result: TmkResult<String>, data: Data, channelCount: Int) {
        _ = (engine, result, channelCount)
        if channelCount == 2 {
            voiceIO?.enqueuePlaybackPCM(data)
        } else if let stereo = TmkTranslationPCMTools.mixStereo16LE(left: data, right: data) {
            voiceIO?.enqueuePlaybackPCM(stereo)
        } else {
            voiceIO?.enqueuePlaybackPCM(data)
        }
    }

    func onError(_ error: TmkTranslationError) {
        emitError(code: "translation_error", message: error.localizedDescription)
    }

    func onEvent(name: String, args: Any?) {
        _ = args
        emitLog(name)
    }

    func onOfflineModelEvent(name: String, args: Any?) {
        _ = args
        emitLog(name)
    }

    func onOfflineModelError(_ error: TmkTranslationError) {
        emitError(code: "offline_download_failed", message: error.localizedDescription)
    }

    func onOfflineModelDownloadProgress(fileName: String, index: Int, total: Int, downloaded: Int64, fileTotal: Int64) {
        let progress = fileTotal > 0 ? Double(downloaded) / Double(fileTotal) : nil
        emitDownload(message: "($index/$total) \(fileName)", progress: progress)
    }

    func onOfflineModelUnzipProgress(fileName: String, progress: Double) {
        emitDownload(message: "解压 \(fileName)", progress: progress)
    }

    func onOfflineModelReady() {
        emitDownload(message: "模型下载完成", progress: 1, stage: "completed", isCompleted: true)
        emitSessionState(statusText: "离线模型已就绪", isModelReady: true)
    }

    func onOfflineModelPackageInfosChanged(_ packages: [TmkOfflineModelPackageInfo]) {
        emitLog("offline packages updated: \(packages.count)")
    }
}

private enum FixedAudioAssetResolver {
    static func fixedPCMData() -> Data? {
        let hostBundle = Bundle(for: TmkTranslationFlutterPlugin.self)
        if let resourceURL = hostBundle.url(forResource: "tmk_translation_flutter_resources", withExtension: "bundle"),
           let resourceBundle = Bundle(url: resourceURL),
           let fileURL = resourceBundle.url(forResource: "right_audio", withExtension: "pcm") {
            return try? Data(contentsOf: fileURL)
        }
        if let fileURL = hostBundle.url(forResource: "right_audio", withExtension: "pcm") {
            return try? Data(contentsOf: fileURL)
        }
        return nil
    }
}

private func closeRoom(_ room: TmkTranslationRoom) -> TmkTranslationRoom? {
    _ = room.closeRoom { _ in }
    return nil
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
