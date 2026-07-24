//
//  Offline1V1ViewModel.swift
//  TmkTranslationSDKDemo
//
//  Created by Kiro on 2026/4/2.
//

import Foundation
import Combine
import TmkTranslationSDK
import AVFoundation

typealias OfflineOneToOneLanguageOption = (code: String, name: String)

/// 离线能力档位选项（照抄 `OneToOneScenarioOption`，复用在线 `TmkRoomScenario`）。
/// - recognize：只识别；toText：识别+翻译；toSpeech：完整链路（默认）。
enum OfflineScenarioOption: CaseIterable, Equatable {
    case toSpeech
    case recognize
    case toText

    static let defaultOption: OfflineScenarioOption = .toSpeech

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

    /// 该档位所需的离线模型能力（供模型下载/就绪按能力粒度传参）。
    var needsMT: Bool { self != .recognize }
    var needsTTS: Bool { self == .toSpeech }
}

/// 离线切语言/升档时,若目标语言对/目标档位所需模型未就绪,向 Controller 抛出的"待下载确认"提示。
/// 两套离线 Demo(收听/一对一)共用。Controller 订阅到即弹确认框,确认后按此信息按档位下差量包。
struct OfflinePendingDownloadPrompt: Equatable {
    let sourceLang: String
    let targetLang: String
    /// 目标档位:确认下载时按此档位的 needsMT/needsTTS 只下所需包。
    let scenarioOption: OfflineScenarioOption
    /// 是否为升档触发(true=升档,false=切语言);仅用于文案区分。
    let isUpgrade: Bool
    let title: String
    let message: String
}

/// 下载按钮状态枚举。
enum OfflineModelButtonState: Equatable {
    case notDownloaded      // "下载模型"
    case downloading        // "下载中..."
    case checking           // "校验中..."
    case ready              // "已就绪"
    case updateRequired     // "有更新，重新下载"
    case unsupported        // "不支持离线"

    var buttonTitle: String {
        switch self {
        case .notDownloaded: return "下载模型"
        case .downloading: return "下载中..."
        case .checking: return "校验中..."
        case .ready: return "已就绪"
        case .updateRequired: return "有更新，重新下载"
        case .unsupported: return "不支持离线"
        }
    }

    var isEnabled: Bool {
        switch self {
        case .notDownloaded, .updateRequired: return true
        case .downloading, .checking, .ready, .unsupported: return false
        }
    }
}

/// 离线一对一 ViewModel。
/// 复用 OneToOneViewState / OneToOneRowViewData，去除在线房间相关流程，
/// 使用 createOfflineTranslationChannel 创建通道，语言列表使用 SDK 提供的离线支持列表。
final class Offline1V1ViewModel: NSObject {
    @Published private(set) var state = OneToOneViewState()
    let rowMutation = PassthroughSubject<ChatListMutation<OneToOneRowViewData>, Never>()
    @Published private(set) var downloadButtonState: OfflineModelButtonState = .notDownloaded
    @Published private(set) var downloadStatusText: String = ""
    @Published private(set) var showCancelButton: Bool = false
    @Published private(set) var modelPackageInfos: [TmkOfflineModelPackageInfo] = []
    @Published private(set) var supportedLanguages: [OfflineOneToOneLanguageOption] = []
    let runtimePrompt = PassthroughSubject<DemoConversationPrompt, Never>()
    /// 切语言/升档预检未就绪时的"待下载确认"提示;Controller 订阅到即弹确认框。
    let pendingDownloadPrompt = PassthroughSubject<OfflinePendingDownloadPrompt, Never>()

    private var channel: TmkTranslationChannel?
    private var voiceIO: TmkVoiceProcessingIO?
    private var hasStoppedListening = false
    /// 当前待下载信息(引导下载场景):点"下载"时按此下差量包,点"取消"时清空。
    private var pendingDownloadInfo: OfflinePendingDownloadPrompt?
    /// 标记本次下载是否由"切语言/升档引导"触发:true 则下载完成只提示手动重试,不自动继续。
    private var isGuidedDownload = false
    /// 留存本次引导下载的来源:true=升档,false=切语言。因 pendingDownloadInfo 在下载完成前会被清,需单独保存以选正确的重试文案。
    private var guidedDownloadIsUpgrade = false

    private var rows: [OneToOneRowViewData] = []
    private var bubbleIndexMap: [String: Int] = [:]
    private var bubbleLaneMap: [String: OneToOneRowViewData.Lane] = [:]
    private let bubbleAssembler = DemoConversationBubbleAssembler()
    private var pendingRowsPublishWorkItem: DispatchWorkItem?
    private var lastPublishedRows: [OneToOneRowViewData] = []
    private var selectedSourceLang = "zh"
    private var selectedTargetLang = "en"
    private var selectedRightLang: String { selectedSourceLang }
    private var selectedLeftLang: String { selectedTargetLang }
    private var selectedLeftSpeakerGender: TmkSpeakerGender? = .male
    private var selectedRightSpeakerGender: TmkSpeakerGender? = .female
    @Published private(set) var channelAudioMode: TmkChannelAudioMode = .standard
    /// 翻译下发模式：离线 Demo 默认 partial（展示中间态翻译）。
    @Published private(set) var selectedTranslateMode: TmkTranslateDeliveryMode = .partial
    /// 能力档位：默认 toSpeech（完整链路）。
    @Published private(set) var selectedScenarioOption: OfflineScenarioOption = .defaultOption
    private var selectedChannelModeConfiguration: OneToOneChannelModeConfiguration = OneToOneStandardChannelModeConfiguration()
    private let maxDisplayedRows = 200
    private var downloadStatusHeader = ""

    private let stateLock = NSLock()
    private var isListeningActive = false
    private var playbackMode: OneToOnePlaybackMode = .left
    private var lastSpeechStartMetadataAt: Date?
    private let speechStartTraceMinInterval: TimeInterval = 6

    // 每帧音频回调的 state 发布去重基线：playbackChannels / capture 信息在整通话中几乎恒定，
    // 无守卫会导致每帧 TTS/录音帧都深拷贝含 rows 的 OneToOneViewState 并触发 @Published 全量发布 +
    // Controller render，是 1v1 主线程持续 CPU 的主因（OfflineListen 侧一直有此守卫，1v1 遗漏）。
    private var lastPlaybackChannels = 0
    private var lastCaptureSampleRate = 0
    private var lastCaptureChannels = 0

    /// 模型根目录（App Documents/tmkOfflineModel/）。
    private var modelRootDirectory: String {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("tmkOfflineModel").path
    }

    var currentLeftSpeakerGender: TmkSpeakerGender {
        selectedLeftSpeakerGender ?? .male
    }

    var currentRightSpeakerGender: TmkSpeakerGender {
        selectedRightSpeakerGender ?? .female
    }

    /// 本地 PCM 文件数据（预加载），用于左声道输入。
    private lazy var localPCMData: Data? = {
        guard let path = Bundle.main.path(forResource: "right_audio", ofType: "pcm") else { return nil }
        return try? Data(contentsOf: URL(fileURLWithPath: path))
    }()
    private lazy var leftFileAudioLoopBuffer = OneToOneLocalAudioLoopBuffer(pcmData: localPCMData)
    private var offlineSupportChecked = false
    private var offlineTranslationSupported = false

    func configureInitialLanguages(source: String?, target: String?) {
        if let source, source.isEmpty == false {
            selectedSourceLang = source
        }
        if let target, target.isEmpty == false {
            selectedTargetLang = target
        }
    }

    func onViewDidLoad() {
        loadOfflineSupportedLanguages()
        updateStateOnMain {
            $0.sourceLanguage = self.selectedSourceLang
            $0.targetLanguage = self.selectedTargetLang
            $0.currentMode = "offline"
            $0.currentScenario = "oneToOne"
            $0.configuredChannels = self.channelModeConfiguration.pcmChannels
        }
        verifyAuthThenRefreshOfflineState(autoStartIfReady: true)
    }

    func onViewWillClose() {
        TmkTranslationSDK.shared.cancelOfflineModelDownload()
        stopListeningIfNeeded()
    }

    /// 检查模型就绪状态并更新按钮。
    func checkModelReadyAndUpdateButton(autoStartIfReady: Bool = true,
                                        autoDownloadIfNeeded: Bool = false) {
        guard offlineTranslationSupported else {
            applyOfflineUnsupportedState()
            return
        }
        let packageInfos = TmkTranslationSDK.shared.getOfflineModelPackageInfos(
            srcLang: selectedRightLang,
            dstLang: selectedLeftLang,
            scenario: .oneToOne,
            needMt: selectedScenarioOption.needsMT,
            needTts: selectedScenarioOption.needsTTS
        )
        let ready = TmkTranslationSDK.shared.isOfflineModelReady(
            srcLang: selectedRightLang,
            dstLang: selectedLeftLang,
            scenario: .oneToOne,
            needMt: selectedScenarioOption.needsMT,
            needTts: selectedScenarioOption.needsTTS
        )
        DispatchQueue.main.async {
            self.modelPackageInfos = packageInfos
            self.updateDownloadPackageListStatusText()
            if ready {
                self.downloadButtonState = .ready
                self.updateDownloadPackageListStatusText(header: "模型已就绪")
                if autoStartIfReady {
                    self.createOfflineChannel()
                }
            } else {
                self.stopCurrentChannelForMissingModels()
                self.downloadButtonState = .notDownloaded
                self.updateDownloadPackageListStatusText(
                    header: "当前模型资源不完整，需要先下载"
                )
                self.updateStatus("当前模型资源不完整，需要先下载离线资源")
                self.updateStateOnMain {
                    $0.canStartListening = false
                    $0.canStopListening = false
                }
                if autoDownloadIfNeeded {
                    self.startModelDownloadIfSupported()
                }
            }
        }
    }

    /// 触发模型下载。
    func downloadModel() {
        if offlineSupportChecked == false {
            verifyAuthThenRefreshOfflineState(autoStartIfReady: false, autoDownloadIfNeeded: true)
            return
        }
        guard offlineTranslationSupported else {
            applyOfflineUnsupportedState()
            return
        }
        startModelDownloadIfSupported()
    }

    /// 取消模型下载。
    func cancelDownload() {
        TmkTranslationSDK.shared.cancelOfflineModelDownload()
        // 取消下载:两个引导标志成对复位,避免残留污染下次普通下载。
        isGuidedDownload = false
        guidedDownloadIsUpgrade = false
        downloadButtonState = .notDownloaded
        downloadStatusText = "下载已取消"
        showCancelButton = false
    }

    func startListening() {
        guard offlineTranslationSupported else {
            applyOfflineUnsupportedState()
            return
        }
        guard TmkTranslationSDK.shared.isOfflineModelReady(
            srcLang: selectedRightLang,
            dstLang: selectedLeftLang,
            scenario: .oneToOne,
            needMt: selectedScenarioOption.needsMT,
            needTts: selectedScenarioOption.needsTTS
        ) else {
            updateStatus("当前模型资源不完整，需要先下载离线资源")
            checkModelReadyAndUpdateButton(autoStartIfReady: false)
            return
        }
        guard state.canStartListening, let channel else {
            updateStatus("离线通道尚未就绪，请等待模型校验和初始化完成")
            return
        }
        resetLocalPCMPlaybackState()
        if voiceIO == nil {
            voiceIO = TmkVoiceProcessingIO(config: TmkVPConfig(sampleRate: 16_000,
                                                               channels: 1,
                                                               bitsPerChannel: 16,
                                                               framesPerBuffer: 1024))
        }
        guard let voiceIO else { return }
        voiceIO.resolveVADState = nil
        hasStoppedListening = false
        configureInterruptionHandling(for: voiceIO)
        do {
            try voiceIO.activateAudioSession(sampleRate: 16000,
                                             framesPerBuffer: 1024,
                                             mode: .voiceChat,
                                             useSpeaker: true)
        } catch {
            updateStatus("音频会话配置失败：\(error.localizedDescription)")
            return
        }
        voiceIO.onInputPCM = { [weak self, weak channel] data, format, vadState in
            guard let self else { return }
            if vadState == .speechStart, let channel {
                self.sendRightMicSpeechStartMetadataIfNeeded(channel: channel)
            }
            let captureChannels = Int(format.mChannelsPerFrame)
            self.updateCaptureAudioInfo(sampleRate: Int(format.mSampleRate), channels: captureChannels)
            // 本地音频 -> 左声道，麦克风录音 -> 右声道。
            let recordData = data.count.isMultiple(of: 2) ? data : Data(data.prefix(data.count - 1))
            guard recordData.isEmpty == false else { return }
            let fileChunk = self.nextLeftFileAudioChunk(expectedLength: recordData.count)
            guard let channel else { return }
            if fileChunk.startsNewCycle {
                self.sendLeftFileSpeechStartMetadata(channel: channel)
            }
            let plans = self.channelModeConfiguration.makeInputAudioPushPlan(fileData: fileChunk.data, rightMicData: recordData)
            for plan in plans {
                switch plan.destination {
                case .interleaved(let channelCount):
                    channel.pushStreamAudioData(plan.data, channelCount: channelCount, extraChunk: nil)
                case .speaker(let speakerChannel):
                    channel.pushStreamAudioData(plan.data, speakerChannel: speakerChannel, extraChunk: nil)
                }
            }
        }
        voiceIO.requestRecordPermission { [weak self] granted in
            guard let self else { return }
            guard granted else {
                self.updateStatus("麦克风权限未授权")
                return
            }
            do {
                try voiceIO.start()
                self.setListeningActive(true)
                self.updateStateOnMain {
                    $0.canStopListening = true
                    $0.canStartListening = false
                }
                self.updateStatus("离线一对一收听中...")
            } catch {
                self.updateStatus("开始收听失败：\(error.localizedDescription)")
            }
        }
    }

    func stopListening() {
        voiceIO?.stop()
        resetLocalPCMPlaybackState()
        setListeningActive(false)
        lastSpeechStartMetadataAt = nil
        // 复位每帧发布去重基线：下次开始收听时首帧会重新发布一次采集/回放信息。
        lastPlaybackChannels = 0
        lastCaptureSampleRate = 0
        lastCaptureChannels = 0
        updateStateOnMain {
            $0.canStopListening = false
            $0.canStartListening = self.channel != nil
        }
        updateStatus("收听已停止")
    }

    /// 配置采集中断/恢复事件处理：来电等中断结束后录音器会自动恢复，这里仅同步 UI 文案。
    private func configureInterruptionHandling(for voiceIO: TmkVoiceProcessingIO) {
        voiceIO.onInterruptionEvent = { [weak self] event in
            guard let self else { return }
            switch event {
            case .interrupted:
                self.updateStatus("通话中断，已暂停收听...")
            case .resumed:
                self.updateStatus("离线一对一收听中...")
            case .resumeFailed(let error):
                self.updateStatus("恢复收听失败，请重试：\(error.localizedDescription)")
                self.setListeningActive(false)
                self.updateStateOnMain {
                    $0.canStopListening = false
                    $0.canStartListening = self.channel != nil
                }
            }
        }
    }

    func setPlaybackMode(_ mode: OneToOnePlaybackMode) {
        playbackMode = mode
        // 切换播放音源时清空历史播放缓存，避免旧声道残留音频影响新声道体验。
        voiceIO?.clearPlaybackBuffer()
        updateStateOnMain { $0.playbackMode = mode }
    }

    func setChannelAudioMode(_ mode: TmkChannelAudioMode) {
        guard channelAudioMode != mode else { return }
        channelAudioMode = mode
        selectedChannelModeConfiguration = OneToOneChannelModeConfigurationFactory.make(mode: mode)
        let title = mode.oneToOneDemoTitle
        updateStateOnMain {
            $0.configuredChannels = self.channelModeConfiguration.pcmChannels
        }
        guard channel != nil else {
            updateStatus("离线一对一通道模式已切换为 \(title)，将在通道创建后生效")
            return
        }
        resetAndRecreateChannel(reason: "离线一对一通道模式已切换为 \(title)，正在重启离线通道...")
    }

    func applySourceLanguage(_ code: String) {
        guard code != selectedTargetLang else {
            updateStatus("源语言和目标语言不能相同")
            return
        }
        applyLanguages(source: code, target: selectedTargetLang)
    }

    func applyTargetLanguage(_ code: String) {
        guard code != selectedSourceLang else {
            updateStatus("源语言和目标语言不能相同")
            return
        }
        applyLanguages(source: selectedSourceLang, target: code)
    }

    /// 应用新的源/目标语言。
    ///
    /// 优先走 SDK 运行时切换语言接口 `channel.updateLanguages`（销毁重建三段离线模型，
    /// 不重建整个通道、不重新鉴权）；仅在通道尚未创建时才回退到「保存选择 + 重建通道」。
    ///
    /// 离线切换语言不可取消、无超时，仅在真正开始 native 重建前做检查（语言支持 / 模型就绪 /
    /// 通道须已 running）失败即回错；一旦开始重建即承诺走到成功（含秒级模型重载耗时）。
    func applyLanguages(source: String, target: String) {
        // 通道尚未创建：保存选择，等通道创建后按新语言生效。
        guard let channel else {
            selectedSourceLang = source
            selectedTargetLang = target
            updateStateOnMain {
                $0.sourceLanguage = source
                $0.targetLanguage = target
            }
            updateStatus("语言已保存，将在离线通道创建后生效")
            return
        }

        // 切语言预检：目标语言对在当前档位下模型未就绪时，不下发，弹确认框引导下载。
        // iOS 本就"成功回调才落地 selectedSourceLang/selectedTargetLang"，此处不下发即保持旧值。
        guard TmkTranslationSDK.shared.isOfflineModelReady(
            srcLang: source,
            dstLang: target,
            scenario: .oneToOne,
            needMt: selectedScenarioOption.needsMT,
            needTts: selectedScenarioOption.needsTTS
        ) else {
            requestGuidedDownload(source: source,
                                  target: target,
                                  option: selectedScenarioOption,
                                  isUpgrade: false)
            return
        }

        updateStatus("正在切换离线语言 \(source) ↔ \(target)（重载模型，请稍候）...")
        _ = channel.updateLanguages(sourceLang: source, targetLang: target) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                // 切换成功后才落地本地选择，保证 UI 与底层一致。
                self.selectedSourceLang = source
                self.selectedTargetLang = target
                self.updateStateOnMain {
                    $0.sourceLanguage = source
                    $0.targetLanguage = target
                }
                self.updateStatus("离线语言已切换为 \(source) ↔ \(target)")
            case .failure(let error):
                self.updateStatus("离线语言切换失败：\(error.message)")
            }
        }
    }

    /// 运行时切换翻译模式（partial/stable）。未创建通道时仅记录，下次创建生效。
    func updateTranslateMode(_ mode: TmkTranslateDeliveryMode) {
        selectedTranslateMode = mode
        guard let channel else {
            updateStatus("翻译模式已保存(\(mode == .partial ? "partial" : "stable"))，将在离线通道创建后生效")
            return
        }
        updateStatus("正在切换翻译模式为 \(mode == .partial ? "partial" : "stable")...")
        channel.updateTranslateMode(mode) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.updateStatus("翻译模式已切换为 \(mode == .partial ? "partial" : "stable")")
            case .failure(let error):
                self.updateStatus("翻译模式切换失败：\(error.message)")
            }
        }
    }

    /// 切换能力档位（recognize / speech_to_text / speech_to_speech）。
    /// 未建通道时仅保存，建通道后运行时调 `channel.updateScenario`。
    ///
    /// 升档（needsMT/needsTTS 相对当前档位从无到有）时若目标档位所需模型未就绪，
    /// 不下发、弹确认框引导下载，`selectedScenarioOption` 保持旧值（成功回调才落地）。
    func updateScenario(_ option: OfflineScenarioOption) {
        // 通道尚未创建：仅保存，等通道创建后按新档位生效。
        guard let channel else {
            selectedScenarioOption = option
            updateStatus("能力档位已保存(\(option.title))，将在离线通道创建后生效")
            return
        }
        // 升档预检：档位从无到有引入 MT/TTS 能力且目标档位模型未就绪时，不下发，弹确认框引导下载。
        let isUpgrade = (option.needsMT && !selectedScenarioOption.needsMT)
            || (option.needsTTS && !selectedScenarioOption.needsTTS)
        if isUpgrade,
           TmkTranslationSDK.shared.isOfflineModelReady(
               srcLang: selectedRightLang,
               dstLang: selectedLeftLang,
               scenario: .oneToOne,
               needMt: option.needsMT,
               needTts: option.needsTTS
           ) == false {
            requestGuidedDownload(source: selectedRightLang,
                                  target: selectedLeftLang,
                                  option: option,
                                  isUpgrade: true)
            return
        }
        updateStatus("正在切换能力档位为 \(option.title)...")
        channel.updateScenario(option.roomScenario) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                // 切换成功后才落地档位，保证 UI 与底层一致。
                self.selectedScenarioOption = option
                self.updateStatus("能力档位已切换为 \(option.title)")
            case .failure(let error):
                self.updateStatus("能力档位切换失败：\(error.message)")
            }
        }
    }

    func updateSpeaker(channel speakerChannel: TmkSpeakerChannel, gender: TmkSpeakerGender) {
        switch speakerChannel {
        case .left:
            selectedLeftSpeakerGender = gender
        case .right:
            selectedRightSpeakerGender = gender
        }

        let speaker = TmkSpeaker(channel: speakerChannel, gender: gender)
        guard let channel else {
            updateStatus("音色已保存，将在离线通道创建后生效")
            return
        }
        updateStatus("正在切换离线音色...")
        channel.updateSpeaker(speakers: [speaker]) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.updateStatus("离线音色已切换，下一次合成生效")
            case .failure(let error):
                self.updateStatus("离线音色切换失败：\(error.message)")
            }
        }
    }

    func updateSpeakers(left: TmkSpeakerGender, right: TmkSpeakerGender) {
        selectedLeftSpeakerGender = left
        selectedRightSpeakerGender = right
        let speakers = [
            TmkSpeaker(channel: .left, gender: left),
            TmkSpeaker(channel: .right, gender: right)
        ]
        guard let channel else {
            updateStatus("音色已保存，将在离线通道创建后生效")
            return
        }
        updateStatus("正在切换离线音色...")
        channel.updateSpeaker(speakers: speakers) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.updateStatus("离线左右声道音色已切换，下一次合成生效")
            case .failure(let error):
                self.updateStatus("离线音色切换失败：\(error.message)")
            }
        }
    }

    func restartAfterRuntimePrompt() {
        resetAndRecreateChannel(reason: "正在重新初始化离线一对一通道...")
    }

    /// 切语言/升档预检未就绪时调用：记录待下载信息并向 Controller 抛"待下载确认"提示。
    func requestGuidedDownload(source: String,
                               target: String,
                               option: OfflineScenarioOption,
                               isUpgrade: Bool) {
        let sourceName = displayLanguageName(source)
        let targetName = displayLanguageName(target)
        let action = isUpgrade ? "切换到「\(option.title)」" : "切换语言"
        let prompt = OfflinePendingDownloadPrompt(
            sourceLang: source,
            targetLang: target,
            scenarioOption: option,
            isUpgrade: isUpgrade,
            title: "模型未就绪",
            message: "\(action)需要的离线模型（\(sourceName) ↔ \(targetName)，档位「\(option.title)」）尚未下载。\n是否现在下载?下载完成后请手动重试。"
        )
        pendingDownloadInfo = prompt
        updateStatus("目标模型未就绪，请下载后重试")
        DispatchQueue.main.async {
            self.pendingDownloadPrompt.send(prompt)
        }
    }

    /// 用户确认下载：按待下载信息的目标语言对 + 目标档位 needsMT/needsTTS 下差量包（不改 UI 语言/档位）。
    func confirmPendingDownload() {
        guard let info = pendingDownloadInfo else { return }
        guard offlineTranslationSupported else {
            applyOfflineUnsupportedState()
            return
        }
        // 标记本次为引导下载：完成后只提示手动重试，不自动继续切换。
        isGuidedDownload = true
        // 留存来源(升档/切语言),下载完成时据此选正确的重试文案。
        guidedDownloadIsUpgrade = info.isUpgrade
        downloadButtonState = .downloading
        downloadStatusText = "准备下载..."
        showCancelButton = true
        TmkTranslationSDK.shared.downloadOfflineModels(
            srcLang: info.sourceLang,
            dstLang: info.targetLang,
            scenario: .oneToOne,
            needMt: info.scenarioOption.needsMT,
            needTts: info.scenarioOption.needsTTS,
            listener: self
        )
    }

    /// 用户取消下载：清待下载状态并提示未切换。
    func cancelPendingDownload() {
        pendingDownloadInfo = nil
        updateStatus("已取消，当前语言未切换")
    }
}

private extension Offline1V1ViewModel {
    var channelModeConfiguration: OneToOneChannelModeConfiguration {
        selectedChannelModeConfiguration
    }

    static func makeLanguageOptions(from response: TmkLocaleListResponse) -> [OfflineOneToOneLanguageOption] {
        response.localeOptions.map {
            return (code: $0.code, name: $0.displayName)
        }
    }

    func loadOfflineSupportedLanguages() {
        _ = TmkTranslationSDK.shared.getOfflineSupportedLanguages { [weak self] result in
            guard let self else { return }
            guard case .success(let response) = result else { return }
            let options = Self.makeLanguageOptions(from: response)
            guard options.isEmpty == false else { return }
            self.supportedLanguages = options
            if options.contains(where: { $0.code == self.selectedSourceLang }) == false {
                self.selectedSourceLang = options.first?.code ?? self.selectedSourceLang
            }
            if options.contains(where: { $0.code == self.selectedTargetLang }) == false {
                self.selectedTargetLang = options.first(where: { $0.code != self.selectedSourceLang })?.code
                    ?? options.first?.code
                    ?? self.selectedTargetLang
            }
            self.updateStateOnMain {
                $0.sourceLanguage = self.selectedSourceLang
                $0.targetLanguage = self.selectedTargetLang
            }
        }
    }

    func verifyAuthThenRefreshOfflineState(autoStartIfReady: Bool,
                                           autoDownloadIfNeeded: Bool = false) {
        downloadButtonState = .checking
        showCancelButton = false
        updateDownloadPackageListStatusText(header: "正在鉴权并检查离线能力...")
        updateStatus("正在鉴权...")
        TmkTranslationSDK.shared.verifyAuth { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.offlineSupportChecked = true
                self.offlineTranslationSupported = TmkTranslationSDK.shared.isOfflineTranslationSupported()
                guard self.offlineTranslationSupported else {
                    self.applyOfflineUnsupportedState()
                    return
                }
                self.checkModelReadyAndUpdateButton(autoStartIfReady: autoStartIfReady,
                                                    autoDownloadIfNeeded: autoDownloadIfNeeded)
            case .failure(let error):
                self.offlineSupportChecked = false
                self.offlineTranslationSupported = false
                self.downloadButtonState = .notDownloaded
                self.showCancelButton = false
                self.updateDownloadPackageListStatusText(header: "鉴权失败，无法使用离线翻译")
                self.updateStatus("鉴权失败：\(error.message)")
                self.stopCurrentChannelForMissingModels()
                self.updateStateOnMain {
                    $0.canStartListening = false
                    $0.canStopListening = false
                }
            }
        }
    }

    func applyOfflineUnsupportedState() {
        stopCurrentChannelForMissingModels()
        downloadButtonState = .unsupported
        showCancelButton = false
        updateDownloadPackageListStatusText(header: "当前账号不支持离线翻译")
        updateStatus("当前账号未开通离线翻译能力")
        updateStateOnMain {
            $0.canStartListening = false
            $0.canStopListening = false
        }
    }

    func startModelDownloadIfSupported() {
        guard offlineTranslationSupported else {
            applyOfflineUnsupportedState()
            return
        }
        // 普通"下载当前语言模型"按钮触发:非引导下载,完成后保持原自动继续行为。
        // 两个引导标志成对复位,防止上次引导下载的残留把本次普通下载误判为引导。
        isGuidedDownload = false
        guidedDownloadIsUpgrade = false
        downloadButtonState = .downloading
        downloadStatusText = "准备下载..."
        showCancelButton = true
        TmkTranslationSDK.shared.downloadOfflineModels(
            srcLang: selectedRightLang,
            dstLang: selectedLeftLang,
            scenario: .oneToOne,
            needMt: selectedScenarioOption.needsMT,
            needTts: selectedScenarioOption.needsTTS,
            listener: self
        )
    }

    func createOfflineChannel() {
        guard offlineTranslationSupported else {
            applyOfflineUnsupportedState()
            return
        }
        guard TmkTranslationSDK.shared.isOfflineModelReady(
            srcLang: selectedRightLang,
            dstLang: selectedLeftLang,
            scenario: .oneToOne,
            needMt: selectedScenarioOption.needsMT,
            needTts: selectedScenarioOption.needsTTS
        ) else {
            downloadButtonState = .notDownloaded
            checkModelReadyAndUpdateButton(autoStartIfReady: false, autoDownloadIfNeeded: false)
            updateStatus("当前模型资源不完整，需要先下载离线资源")
            return
        }
        DispatchQueue.main.async {
            self.downloadButtonState = .checking
            self.updateDownloadPackageListStatusText(header: "模型校验中...")
            self.showCancelButton = false
        }
        let builder = TmkTranslationChannelConfig.Builder()
            .setMode(.offline)
            .setScenario(.oneToOne)
            .setSourceLang(selectedRightLang)
            .setTargetLang(selectedLeftLang)
            .setPCMSampleRate(16_000)
            .setPCMChannels(channelModeConfiguration.pcmChannels)
            .setChannelAudioMode(channelAudioMode)
            .setModelRootDirectory(modelRootDirectory)
            .setTranslateMode(selectedTranslateMode)
            .setCapabilityTier(selectedScenarioOption.roomScenario)
        let speakers = configuredSpeakers()
        if speakers.isEmpty == false {
           _ = builder.setSpeakers(speakers)
        }
        let config = builder.build()
        updateStateOnMain {
            $0.configuredSampleRate = config.pcmSampleRate
            $0.configuredChannels = config.pcmChannels
        }
        updateStatus("正在加载离线模型...")
        TmkTranslationSDK.shared.createTranslationChannel(config, listener: self) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let channel):
                self.channel = channel
                self.updateStateOnMain { $0.canStartListening = true }
                self.downloadButtonState = .ready
                self.updateDownloadPackageListStatusText(header: "模型已就绪")
                self.updateStatus(#"离线一对一通道已就绪，点击"开始收听"开始采集"#)
            case .failure(let error):
                self.downloadButtonState = .notDownloaded
                self.checkModelReadyAndUpdateButton(autoStartIfReady: false, autoDownloadIfNeeded: false)
                self.updateStatus("离线通道创建失败：\(error.localizedDescription)")
            }
        }
    }
    

    func resetAndRecreateChannel(reason: String = "语言已切换，正在重新鉴权并检测离线能力...") {
        voiceIO?.stop()
        resetLocalPCMPlaybackState()
        setListeningActive(false)
        // 复位每帧发布去重基线：末尾自动重启收听，重启后首帧须能重新发布采集/回放信息（对齐 OfflineListen）。
        lastPlaybackChannels = 0
        lastCaptureSampleRate = 0
        lastCaptureChannels = 0
        TmkTranslationSDK.shared.releaseChannel()
        channel = nil
        hasStoppedListening = false
        resetRows()
        updateStateOnMain {
            $0.rows = []
            $0.canStartListening = false
            $0.canStopListening = false
        }
        offlineSupportChecked = false
        offlineTranslationSupported = false
        updateStatus(reason)
        verifyAuthThenRefreshOfflineState(autoStartIfReady: true)
    }

    func configuredSpeakers() -> [TmkSpeaker] {
        var speakers: [TmkSpeaker] = []
        if let selectedLeftSpeakerGender {
            speakers.append(TmkSpeaker(channel: .left, gender: selectedLeftSpeakerGender))
        }
        if let selectedRightSpeakerGender {
            speakers.append(TmkSpeaker(channel: .right, gender: selectedRightSpeakerGender))
        }
        return speakers
    }

    func sendRightMicSpeechStartMetadataIfNeeded(channel: TmkTranslationChannel) {
        guard shouldSendSpeechStartTrace(now: Date()) else { return }
        for metadataChannel in selectedChannelModeConfiguration.speechStartMetadataChannelsForCurrentVADSource {
            sendSpeechStartMetadata(channel: channel,
                                    metadataChannel: metadataChannel,
                                    label: "right mic")
        }
    }

    func sendLeftFileSpeechStartMetadata(channel: TmkTranslationChannel) {
        sendSpeechStartMetadata(channel: channel,
                                metadataChannel: OneToOneSpeechMetadataRouting.channelForLeftFileLoop(),
                                label: "left file")
    }

    func sendSpeechStartMetadata(channel: TmkTranslationChannel, metadataChannel: UInt8, label: String) {
        let traceResult = channel.sendAudioMetadata(vadStatus: 0, channel: metadataChannel, baseTraceId: nil)
        switch traceResult {
        case .success(let traceId):
            NSLog("[Offline1V1] %@ speechStart metadata channel=%d traceId=%@", label, metadataChannel, traceId)
        case .failure(let error):
            NSLog("[Offline1V1] %@ speechStart metadata channel=%d failed=%@", label, metadataChannel, error.localizedDescription)
        }
    }

    func stopListeningIfNeeded() {
        guard hasStoppedListening == false else { return }
        hasStoppedListening = true
        pendingRowsPublishWorkItem?.cancel()
        pendingRowsPublishWorkItem = nil
        setListeningActive(false)
        voiceIO?.stop()
        resetLocalPCMPlaybackState()
        lastSpeechStartMetadataAt = nil
        voiceIO = nil
        TmkTranslationSDK.shared.releaseChannel()
        channel = nil
        updateStatus("已停止收听")
    }

    func stopConversationForRuntimePrompt(status: String) {
        pendingRowsPublishWorkItem?.cancel()
        pendingRowsPublishWorkItem = nil
        voiceIO?.stop()
        resetLocalPCMPlaybackState()
        setListeningActive(false)
        lastSpeechStartMetadataAt = nil
        // 复位每帧发布去重基线：本方法清 playbackChannels=0，重启收听后须能重新发布一次，否则守卫误判致 UI 停在 0。
        lastPlaybackChannels = 0
        lastCaptureSampleRate = 0
        lastCaptureChannels = 0
        voiceIO = nil
        TmkTranslationSDK.shared.releaseChannel()
        channel = nil
        updateStateOnMain {
            $0.canStartListening = false
            $0.canStopListening = false
            $0.playbackChannels = 0
            $0.statusText = status
        }
    }

    func applyRuntimeAction(_ action: DemoConversationRuntimeAction) {
        switch action {
        case .none, .ignore:
            return
        case .status(let text), .weakNetwork(let text), .reconnecting(let text):
            updateStatus(text)
        case .prompt(let prompt):
            stopConversationForRuntimePrompt(status: prompt.title)
            DispatchQueue.main.async {
                self.runtimePrompt.send(prompt)
            }
        }
    }

    func stopCurrentChannelForMissingModels() {
        voiceIO?.stop()
        resetLocalPCMPlaybackState()
        setListeningActive(false)
        lastSpeechStartMetadataAt = nil
        TmkTranslationSDK.shared.releaseChannel()
        channel = nil
    }

    func resetRows() {
        rows.removeAll()
        bubbleIndexMap.removeAll()
        bubbleLaneMap.removeAll()
        bubbleAssembler.reset()
        lastPublishedRows = []
        pendingRowsPublishWorkItem?.cancel()
        pendingRowsPublishWorkItem = nil
        rowMutation.send(.reset(rows: []))
    }

    /// 将本地 PCM 文件放入左声道，将麦克风单声道放入右声道。
    func mixLocalToLeftAndMicToRight(micMono: Data) -> Data {
        let leftChunk = nextLeftFileAudioChunk(expectedLength: micMono.count)
        return TmkTranslationPCMTools.mixStereo16LE(left: leftChunk.data, right: micMono) ?? micMono
    }

    func nextLeftFileAudioChunk(expectedLength: Int) -> OneToOneLocalAudioLoopChunk {
        leftFileAudioLoopBuffer.nextLoopChunk(expectedLength: expectedLength)
    }

    func resetLocalPCMPlaybackState() {
        leftFileAudioLoopBuffer.reset()
    }

    func updateStatus(_ text: String) {
        updateStateOnMain { $0.statusText = text }
    }

    /// 语言码 → 展示名（用于待下载提示文案），未命中回退语言码本身。
    func displayLanguageName(_ code: String) -> String {
        supportedLanguages.first(where: { $0.code == code })?.name ?? code
    }

    func updateCaptureAudioInfo(sampleRate: Int, channels: Int) {
        // 采集参数恒定 → 仅值变时发布，避免每个录音帧全量拷贝+发布 state。
        guard lastCaptureSampleRate != sampleRate || lastCaptureChannels != channels else { return }
        lastCaptureSampleRate = sampleRate
        lastCaptureChannels = channels
        updateStateOnMain {
            $0.captureSampleRate = sampleRate
            $0.captureChannels = channels
        }
    }

    func updateStateOnMain(_ action: @escaping (inout OneToOneViewState) -> Void) {
        DispatchQueue.main.async {
            var newState = self.state
            action(&newState)
            self.state = newState
        }
    }

    func updateDownloadPackageListStatusText(header: String? = nil) {
        if let header {
            downloadStatusHeader = header
        }
        let lines = modelPackageInfos.map { Self.formatPackageLine($0) }
        if downloadStatusHeader.isEmpty == false {
            downloadStatusText = ([downloadStatusHeader] + lines).joined(separator: "\n")
        } else {
            downloadStatusText = lines.joined(separator: "\n")
        }
    }

    func setListeningActive(_ active: Bool) {
        stateLock.lock()
        isListeningActive = active
        stateLock.unlock()
    }

    func getListeningActive() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return isListeningActive
    }

    func shouldSendSpeechStartTrace(now: Date) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        if let last = lastSpeechStartMetadataAt,
           now.timeIntervalSince(last) <= speechStartTraceMinInterval {
            return false
        }
        lastSpeechStartMetadataAt = now
        return true
    }

    func extractChannel(from result: TmkResult<String>) -> OneToOneRowViewData.Lane {
        if let ch = result.extraData["channel"] as? String {
            return ch == "right" ? .right : .left
        }
        return .left
    }

    func lane(from result: TmkResult<String>) -> OneToOneRowViewData.Lane? {
        if let channel = (result.extraData["channel"] as? String)?.lowercased() {
            return parseLane(channel: channel)
        }
        return nil
    }

    func parseLane(channel: String) -> OneToOneRowViewData.Lane? {
        if channel == OneToOneRowViewData.Lane.left.rawValue { return .left }
        if channel == OneToOneRowViewData.Lane.right.rawValue { return .right }
        return nil
    }

    func resolveLane(bubbleId: String,
                     sessionId: Int,
                     explicitLane: OneToOneRowViewData.Lane?,
                     sourceLangCode: String,
                     targetLangCode: String) -> OneToOneRowViewData.Lane {
        if let explicitLane {
            bubbleLaneMap[bubbleId] = explicitLane
            return explicitLane
        }
        if let lane = bubbleLaneMap[bubbleId] {
            return lane
        }
        _ = sessionId
        let sourceLower = sourceLangCode.lowercased()
        let targetLower = targetLangCode.lowercased()
        let inferred: OneToOneRowViewData.Lane
        if sourceLower.hasPrefix(sourceLanguagePrefix()) || targetLower.hasPrefix(targetLanguagePrefix()) {
            inferred = .right
        } else {
            inferred = .left
        }
        bubbleLaneMap[bubbleId] = inferred
        return inferred
    }

    func fixedLanguagePair(for lane: OneToOneRowViewData.Lane) -> (source: String, target: String) {
        switch lane {
        case .right:
            return (selectedSourceLang, selectedTargetLang)
        case .left:
            return (selectedTargetLang, selectedSourceLang)
        }
    }

    func normalizedConversationEvent(from event: DemoConversationEvent,
                                     explicitLane: OneToOneRowViewData.Lane?) -> DemoConversationEvent {
        let lane = resolveLane(bubbleId: event.bubbleId,
                               sessionId: event.sessionId,
                               explicitLane: explicitLane,
                               sourceLangCode: event.sourceLangCode,
                               targetLangCode: event.targetLangCode)
        let demoLane: DemoConversationLane = lane == .right ? .right : .left
        let languagePair = fixedLanguagePair(for: lane)
        return DemoConversationEvent(bubbleId: event.bubbleId,
                                     sessionId: event.sessionId,
                                     lane: demoLane,
                                     stage: event.stage,
                                     isFinal: event.isFinal,
                                     text: event.text,
                                     sourceLangCode: languagePair.source,
                                     targetLangCode: languagePair.target,
                                     chunkId: event.chunkId)
    }

    func sourceLanguagePrefix() -> String {
        String(selectedSourceLang.split(separator: "-").first ?? "").lowercased()
    }

    func targetLanguagePrefix() -> String {
        String(selectedTargetLang.split(separator: "-").first ?? "").lowercased()
    }

    func audioRoute(from result: TmkResult<String>) -> TmkTranslatedAudioRoute? {
        let routeValue = result.extraData["audio_route"]
        if let route = routeValue as? TmkTranslatedAudioRoute { return route }
        if let route = routeValue as? String { return TmkTranslatedAudioRoute(rawValue: route) }
        return nil
    }

    func bubbleKey(_ bubbleId: String, _ lane: OneToOneRowViewData.Lane) -> String {
        let mapped: DemoConversationLane = lane == .right ? .right : .left
        return DemoConversationBubbleAssembler.rowKey(bubbleId: bubbleId, lane: mapped)
    }

    func applyBubbleSnapshot(_ snapshot: DemoConversationBubbleSnapshot) {
        DispatchQueue.main.async {
            let lane: OneToOneRowViewData.Lane = snapshot.lane == .right ? .right : .left
            let key = self.bubbleKey(snapshot.bubbleId, lane)
            if let rowIndex = self.bubbleIndexMap[key], self.rows.indices.contains(rowIndex) {
                var row = self.rows[rowIndex]
                row.sessionId = snapshot.sessionId
                row.sourceLangCode = snapshot.sourceLangCode
                row.targetLangCode = snapshot.targetLangCode
                row.sourceText = snapshot.sourceText
                row.translatedText = snapshot.translatedText
                row.isBubbleEnded = snapshot.isBubbleEnded
                self.rows[rowIndex] = row
                self.rowMutation.send(.update(row: row, index: rowIndex, heightMayChange: true))
                self.publishRows()
                return
            }
            let row = OneToOneRowViewData(sessionId: snapshot.sessionId,
                                          bubbleId: snapshot.bubbleId,
                                          lane: lane,
                                          sourceLangCode: snapshot.sourceLangCode,
                                          targetLangCode: snapshot.targetLangCode,
                                          sourceText: snapshot.sourceText,
                                          translatedText: snapshot.translatedText,
                                          isBubbleEnded: snapshot.isBubbleEnded)
            self.rows.append(row)
            let newIndex = self.rows.count - 1
            self.bubbleIndexMap[key] = newIndex
            self.rowMutation.send(.insert(row: row, index: newIndex))
            self.trimRowsIfNeeded()
            self.publishRows()
        }
    }

    func trimRowsIfNeeded() {
        guard rows.count > maxDisplayedRows else { return }
        let overflow = rows.count - maxDisplayedRows
        for _ in 0..<overflow {
            rows.removeFirst()
            rowMutation.send(.delete(index: 0))
        }
        rebuildBubbleIndexMap()
    }

    func rebuildBubbleIndexMap() {
        var newMap: [String: Int] = [:]
        var liveBubbleIds = Set<String>()
        for (index, row) in rows.enumerated() {
            newMap[bubbleKey(row.bubbleId, row.lane)] = index
            liveBubbleIds.insert(row.bubbleId)
        }
        bubbleIndexMap = newMap
        // 长跑防泄漏：bubbleLaneMap 随气泡持续新建、仅 resetRows 全量清，
        // 裁剪 rows 时同步收敛，只保留仍存活于 rows 的 bubbleId（否则数小时单调增长致内存递增）。
        if bubbleLaneMap.count > liveBubbleIds.count {
            bubbleLaneMap = bubbleLaneMap.filter { liveBubbleIds.contains($0.key) }
        }
    }

    func publishRows() {
        pendingRowsPublishWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.lastPublishedRows != self.rows else { return }
            self.lastPublishedRows = self.rows
            self.updateStateOnMain { $0.rows = self.rows }
        }
        pendingRowsPublishWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: workItem)
    }

}

extension Offline1V1ViewModel: TmkTranslationListener, TmkOfflineModelDownloadListener {
    func onRecognized(from engine: AbstractChannelEngine, result: TmkResult<String>, isFinal: Bool) {
        _ = engine
        DemoTmkResultLogFormatter.log(DemoTmkResultLogFormatter.makeLine(scene: "Offline1V1", stage: "ASR", result: result, isFinal: isFinal))
        guard let event = DemoConversationEventAdapter.makeRecognizedEvent(from: result, isFinal: isFinal) else { return }
        let normalized = normalizedConversationEvent(from: event, explicitLane: lane(from: result))
        let snapshots = bubbleAssembler.consume(normalized)
        guard snapshots.isEmpty == false else { return }
        snapshots.forEach(applyBubbleSnapshot)
    }

    func onTranslate(from engine: AbstractChannelEngine, result: TmkResult<String>, isFinal: Bool) {
        _ = engine
        DemoTmkResultLogFormatter.log(DemoTmkResultLogFormatter.makeLine(scene: "Offline1V1", stage: "MT", result: result, isFinal: isFinal))
        guard let event = DemoConversationEventAdapter.makeTranslatedEvent(from: result, isFinal: isFinal) else { return }
        let normalized = normalizedConversationEvent(from: event, explicitLane: lane(from: result))
        let snapshots = bubbleAssembler.consume(normalized)
        guard snapshots.isEmpty == false else { return }
        snapshots.forEach(applyBubbleSnapshot)
    }

    func onAudioDataReceive(from engine: AbstractChannelEngine, result: TmkResult<String>, data: Data, channelCount: Int) {
        _ = engine
        guard result.data == "translated_audio", data.isEmpty == false else { return }
        guard getListeningActive() else { return }
        // channelCount 恒定 → 仅值变时发布，避免每帧 TTS 音频全量拷贝+发布 state（对齐 OfflineListen）。
        if lastPlaybackChannels != channelCount {
            lastPlaybackChannels = channelCount
            updateStateOnMain { $0.playbackChannels = channelCount }
        }
        guard let playbackData = OneToOneTranslatedAudioPlaybackSelector.selectPlaybackData(
            data: data,
            channelCount: channelCount,
            playbackMode: playbackMode,
            audioRoute: audioRoute(from: result),
            sourceLane: extractChannel(from: result),
            extraData: result.extraData
        ) else { return }
        voiceIO?.enqueuePlaybackPCM(playbackData)
    }

    func onError(_ error: TmkTranslationError) {
        applyRuntimeAction(DemoConversationRuntimePolicy.action(for: error))
        // 下载错误时恢复按钮状态。
        DispatchQueue.main.async {
            if self.downloadButtonState == .downloading {
                // 下载失败:两个引导标志成对复位。
                self.isGuidedDownload = false
                self.guidedDownloadIsUpgrade = false
                self.downloadButtonState = .notDownloaded
                self.updateDownloadPackageListStatusText(header: "下载出错：\(error.message)")
                self.showCancelButton = false
            }
        }
    }

    func onEvent(name: String, args: Any?) {
        if name == "offline_bubble_end",
           let result = args as? TmkResult<String> {
            let snapshots = bubbleAssembler.markBubbleEnded(bubbleId: result.bubbleId)
            DemoTmkResultLogFormatter.log(DemoTmkResultLogFormatter.makeBubbleEndLine(scene: "Offline1V1",
                                                                     result: result,
                                                                     affectedSnapshots: snapshots))
            snapshots.forEach(applyBubbleSnapshot)
            return
        }
        _ = args
    }

    func onStateChanged(from engine: AbstractChannelEngine, snapshot: TmkTranslationChannelStateSnapshot) {
        _ = engine
        applyRuntimeAction(DemoConversationRuntimePolicy.action(for: snapshot,
                                                                readyMessage: #"离线一对一通道已就绪，点击"开始收听"开始采集"#,
                                                                isListening: getListeningActive()))
    }

    func onOfflineModelEvent(name: String, args: Any?) {
        _ = args
        if name == "offline_model_cancelled" {
            DispatchQueue.main.async {
                // 下载取消:两个引导标志成对复位。
                self.isGuidedDownload = false
                self.guidedDownloadIsUpgrade = false
                self.downloadButtonState = .notDownloaded
                self.updateDownloadPackageListStatusText(header: "下载已取消")
                self.showCancelButton = false
            }
        } else if name == "offline_model_update_required" {
            DispatchQueue.main.async {
                self.downloadButtonState = .updateRequired
                self.updateDownloadPackageListStatusText(header: "模型资源有更新，请重新下载")
                self.showCancelButton = false
                self.updateStateOnMain { $0.canStartListening = false }
            }
        }
    }

    func onOfflineModelError(_ error: TmkTranslationError) {
        onError(error)
    }

    func onOfflineModelDownloadProgress(fileName: String, index: Int, total: Int, downloaded: Int64, fileTotal: Int64) {
        DispatchQueue.main.async {
            self.downloadButtonState = .downloading
            if downloaded == -1 {
                self.updateDownloadPackageListStatusText(header: "当前文件：\(fileName)\n正在下载（\(index)/\(total)）")
            } else {
                let dlStr = Self.formatBytes(downloaded)
                let totalStr = fileTotal > 0 ? Self.formatBytes(fileTotal) : "未知"
                let percentText = Self.formatPercent(downloaded: downloaded, total: fileTotal)
                self.updateDownloadPackageListStatusText(
                    header: "当前文件：\(fileName)\n下载进度：\(percentText)（\(index)/\(total)）\n\(dlStr) / \(totalStr)"
                )
            }
        }
    }

    func onOfflineModelTotalProgress(downloadedBytesAll: Int64, totalBytesAll: Int64) {
        DispatchQueue.main.async {
            guard totalBytesAll > 0 else { return }
            let percent = Self.formatPercent(downloaded: downloadedBytesAll, total: totalBytesAll)
            let dlStr = Self.formatBytes(downloadedBytesAll)
            let totalStr = Self.formatBytes(totalBytesAll)
            // "总进度："前缀被 Controller.displayButtonTitle 识别，用于按钮标题展示总体进度。
            self.updateDownloadPackageListStatusText(header: "总进度：\(percent)（\(dlStr) / \(totalStr)）")
        }
    }

    func onOfflineModelUnzipProgress(fileName: String, progress: Double) {
        DispatchQueue.main.async {
            let pct = Int(progress * 100)
            self.updateDownloadPackageListStatusText(header: "解压 \(fileName) \(pct)%")
        }
    }

    func onOfflineModelReady() {
        DispatchQueue.main.async {
            self.downloadButtonState = .ready
            self.showCancelButton = false
            if self.isGuidedDownload {
                // 引导下载（切语言/升档触发）：完成后不自动继续，提示用户手动重试。
                // 按来源选文案:升档→重试切换能力,切语言→重试切换语言。
                let retryTip = self.guidedDownloadIsUpgrade ? "下载完成，请重试切换能力" : "下载完成，请重试切换语言"
                self.isGuidedDownload = false
                self.guidedDownloadIsUpgrade = false
                self.pendingDownloadInfo = nil
                self.updateDownloadPackageListStatusText(header: retryTip)
                self.checkModelReadyAndUpdateButton(autoStartIfReady: false)
                self.updateStatus(retryTip)
            } else {
                // 普通"下载当前语言模型"按钮触发：保持原自动继续行为。
                self.updateDownloadPackageListStatusText(header: "下载完成，正在校验模型完整性...")
                self.checkModelReadyAndUpdateButton(autoStartIfReady: true)
            }
        }
    }

    func onOfflineModelPackageInfosChanged(_ packages: [TmkOfflineModelPackageInfo]) {
        DispatchQueue.main.async {
            self.modelPackageInfos = packages
            self.updateDownloadPackageListStatusText()
        }
    }

    private func setDownloadStatus(_ text: String) {
        downloadStatusText = text
        updateStatus(text)
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        let mb = Double(bytes) / (1024.0 * 1024.0)
        return String(format: "%.1f MB", mb)
    }

    private static func formatPercent(downloaded: Int64, total: Int64) -> String {
        guard total > 0 else { return "--" }
        let percent = min(max(Double(downloaded) / Double(total), 0), 1)
        return String(format: "%.0f%%", percent * 100.0)
    }

    private static func formatPackageLine(_ package: TmkOfflineModelPackageInfo) -> String {
        let stateText: String
        switch package.state {
        case .ready:
            stateText = "已就绪"
        case .needsDownload:
            stateText = "待下载"
        case .needsUpdate:
            stateText = "需更新"
        case .resumable:
            stateText = "可续传"
        case .downloading:
            let percent = formatPercent(downloaded: package.downloadedBytes, total: package.totalBytes)
            let downloaded = formatBytes(package.downloadedBytes)
            let total = package.totalBytes > 0 ? formatBytes(package.totalBytes) : "未知"
            stateText = "下载中 \(percent) \(downloaded)/\(total)"
        case .unzipping:
            let percent = Int(min(max(package.unzipProgress, 0), 1) * 100)
            stateText = "解压中 \(percent)%"
        case .failed:
            stateText = "失败"
        case .cancelled:
            stateText = "已取消"
        }
        return "• \(package.packageKey) [\(stateText)]"
    }
}
