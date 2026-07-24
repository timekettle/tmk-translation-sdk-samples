package co.timekettle.translation.sample

import co.timekettle.translation.TmkTranslationSDK
import co.timekettle.translation.TmkTranslationChannel
import co.timekettle.translation.TmkTranslationException
import android.Manifest
import android.app.Application
import android.content.pm.PackageManager
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.AudioTrack
import android.media.MediaRecorder
import android.util.Log
import androidx.core.content.ContextCompat
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import co.timekettle.translation.Cancelable
import co.timekettle.offlinesdk.vad.VadDetector
import co.timekettle.translation.config.TmkTransChannelConfig
import co.timekettle.translation.core.AbstractChannelEngine
import co.timekettle.translation.enums.Scenario
import co.timekettle.translation.enums.TmkRoomScenario
import co.timekettle.translation.enums.TmkTranslateDeliveryMode
import co.timekettle.translation.enums.TranslationMode
import co.timekettle.sdk.common.enums.TransModeType
import co.timekettle.translation.listener.ActionCallback
import co.timekettle.translation.listener.AuthCallback
import co.timekettle.translation.listener.CreateChannelCallback
import co.timekettle.translation.listener.CreateRoomCallback
import co.timekettle.translation.listener.TmkTranslationListener
import co.timekettle.translation.model.Result
import co.timekettle.sdk.common.models.SpeakerChannel
import co.timekettle.sdk.common.models.SpeakerGender
import co.timekettle.sdk.common.models.TmkSpeaker
import co.timekettle.translation.model.TmkTranslationChannelState
import co.timekettle.translation.model.TmkTranslationChannelStateSnapshot
import co.timekettle.translation.model.TmkTranslationRoom
import co.timekettle.translation.offlinemodel.TmkOfflineModelDownloadListener
import co.timekettle.translation.offlinemodel.TmkOfflineModelPackageInfo
import co.timekettle.translation.offlinemodel.TmkOfflineModelPackageState
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import javax.inject.Inject

@HiltViewModel
class OfflineListenViewModel @Inject constructor(
    private val application: Application
) : ViewModel() {

    companion object {
        private const val TAG = "OfflineListenVM"
        private const val SAMPLE_RATE = 16000
        private const val PCM_16BIT_BYTES = 2
        private const val TTS_QUEUE_MAX_MS = 1_000
        private const val TTS_QUEUE_TARGET_MS = 300

        /** 气泡快照重算去抖窗口(毫秒):合并高频 partial,兼顾流畅与实时。 */
        private const val BUBBLE_REFRESH_THROTTLE_MS = 100L

        /** 离线支持的语言列表 (BCP-47 → 显示名) */
        val SUPPORTED_LANGUAGES = TranslationLanguages.offline
    }

    private data class TtsFrame(val data: ByteArray, val sampleRate: Int, val channelCount: Int)

    private var channel: TmkTranslationChannel? = null
    private var speakerCancelable: Cancelable? = null
    private var localeCancelable: Cancelable? = null
    private var audioRecord: AudioRecord? = null
    private var audioTrack: AudioTrack? = null
    private var audioTrackSampleRate: Int = 0
    private var audioTrackChannelCount: Int = 0
    private val ttsQueueLock = Object()
    private val ttsQueue = java.util.ArrayDeque<TtsFrame>()
    private var ttsQueuedBytes: Int = 0
    private var queuedTtsSampleRate: Int = 0
    private var queuedTtsChannelCount: Int = 0
    private var ttsPlayerThread: Thread? = null
    @Volatile private var isTtsPlayerRunning = false
    private var vadDetector: VadDetector? = null
    @Volatile private var isRecording = false
    @Volatile private var released = false
    @Volatile private var userCancelledDownload = false

    // traceId 计时
    private var currentTraceId: String? = null
    @Volatile private var pendingMetadata: ByteArray? = null
    private var vadStartMs: Long = 0
    private var firstAsrMs: Long = 0
    private var firstMtMs: Long = 0
    private var firstTtsMs: Long = 0

    private val _isModelReady = MutableStateFlow(false)
    val isModelReady: StateFlow<Boolean> = _isModelReady.asStateFlow()

    private val _isDownloading = MutableStateFlow(false)
    val isDownloading: StateFlow<Boolean> = _isDownloading.asStateFlow()

    /** 下载进度提示文本，如 "asr/zh (2/5) 63%" */
    private val _downloadProgress = MutableStateFlow("")
    val downloadProgress: StateFlow<String> = _downloadProgress.asStateFlow()

    private val _offlineModelPackages = MutableStateFlow<List<TmkOfflineModelPackageInfo>>(emptyList())
    val offlineModelPackages: StateFlow<List<TmkOfflineModelPackageInfo>> = _offlineModelPackages.asStateFlow()

    private val _isInitialized = MutableStateFlow(false)
    val isInitialized: StateFlow<Boolean> = _isInitialized.asStateFlow()
    private val _initErrorMessage = MutableStateFlow<String?>(null)
    val initErrorMessage: StateFlow<String?> = _initErrorMessage.asStateFlow()

    private val _isStarted = MutableStateFlow(false)
    val isStarted: StateFlow<Boolean> = _isStarted.asStateFlow()

    private val _isChannelReady = MutableStateFlow(false)
    val isChannelReady: StateFlow<Boolean> = _isChannelReady.asStateFlow()

    private val _isStarting = MutableStateFlow(false)
    val isStarting: StateFlow<Boolean> = _isStarting.asStateFlow()

    private val _conversationErrorPrompt = MutableStateFlow<OnlineConversationErrorPrompt?>(null)
    val conversationErrorPrompt: StateFlow<OnlineConversationErrorPrompt?> = _conversationErrorPrompt.asStateFlow()

    private val _isCheckingOfflineSupport = MutableStateFlow(false)
    val isCheckingOfflineSupport: StateFlow<Boolean> = _isCheckingOfflineSupport.asStateFlow()

    private val _isOfflineSupported = MutableStateFlow(false)
    val isOfflineSupported: StateFlow<Boolean> = _isOfflineSupported.asStateFlow()

    private val _offlineSupportChecked = MutableStateFlow(false)
    val offlineSupportChecked: StateFlow<Boolean> = _offlineSupportChecked.asStateFlow()

    private val _logMessages = MutableStateFlow<List<String>>(emptyList())
    val logMessages: StateFlow<List<String>> = _logMessages.asStateFlow()

    private val bubbleAssembler = DemoConversationBubbleAssembler()
    private val _bubbles = MutableStateFlow<List<DemoConversationBubbleSnapshot>>(emptyList())
    val bubbles: StateFlow<List<DemoConversationBubbleSnapshot>> = _bubbles.asStateFlow()

    // 气泡快照重算节流:高频 ASR/MT partial(每秒数次)若每条都在主线程全量 snapshotWithSegments()
    // (遍历数百气泡 × composeText/Segments,含 LCS),长时间运行会拖垮主线程致 UI 卡死(bug 7051627151)。
    // 用 CONFLATED channel 合并高频请求,由后台协程去抖后在 Dispatchers.Default 计算快照,算完再赋值
    // StateFlow(线程安全,Compose 在主线程收集)。bubbleAssembler 内部有 synchronized 锁,跨线程 consume/snapshot 安全。
    private val bubbleRefreshRequests = Channel<Unit>(Channel.CONFLATED)

    init {
        viewModelScope.launch(Dispatchers.Default) {
            for (ignored in bubbleRefreshRequests) {
                // 合并窗口:一次去抖内到达的多条 partial 只重算一次快照,兼顾流畅与实时。
                kotlinx.coroutines.delay(BUBBLE_REFRESH_THROTTLE_MS)
                val snapshot = bubbleAssembler.snapshotWithSegments()
                _bubbles.value = snapshot
            }
        }
    }

    private val _sourceLang = MutableStateFlow("zh-CN")
    val sourceLang: StateFlow<String> = _sourceLang.asStateFlow()
    private val _targetLang = MutableStateFlow("en-US")
    val targetLang: StateFlow<String> = _targetLang.asStateFlow()

    /** 翻译下发模式(离线中间态开关)。Demo 默认 PARTIAL 展示中间态;可运行时切换验证 D6。 */
    private val _translateMode = MutableStateFlow(TmkTranslateDeliveryMode.PARTIAL)
    val translateMode: StateFlow<TmkTranslateDeliveryMode> = _translateMode.asStateFlow()

    /**
     * 运行时切换翻译下发模式(partial/stable)。若通道已就绪则立即下发([TmkTranslationChannel.updateTranslateMode]);
     * 否则仅更新 UI 状态,下次建通道时按新模式生效。
     */
    fun setTranslateMode(mode: TmkTranslateDeliveryMode) {
        _translateMode.value = mode
        channel?.updateTranslateMode(mode)
        addLog("翻译下发模式切换为 $mode")
    }

    /** 能力档位(三档对齐在线)。Demo 默认 speech_to_speech;可运行时切换,升档需模型就绪(不自动下载)。 */
    private val _scenarioOption = MutableStateFlow(OfflineScenarioOption.defaultOption)
    val scenarioOption: StateFlow<OfflineScenarioOption> = _scenarioOption.asStateFlow()
    private val _isScenarioUpdating = MutableStateFlow(false)
    val isScenarioUpdating: StateFlow<Boolean> = _isScenarioUpdating.asStateFlow()

    /**
     * 运行时切换能力档位(recognize / speech_to_text / speech_to_speech)。通道未就绪则仅存,建通道时经
     * [TmkTransChannelConfig.Builder.setRoomScenario] 生效;已就绪则调 [TmkTranslationChannel.updateScenario]
     * (升档做前置就绪检查、当场补建 MT/TTS session;降档立即释放),成功后刷新模型就绪状态(needMt/needTts 随档位变)。
     */
    fun updateScenario(option: OfflineScenarioOption) {
        val currentChannel = channel
        if (currentChannel == null) {
            _scenarioOption.value = option
            refreshModelReady()
            addLog("能力已设置为${option.title}(${option.roomScenario.value})，将在创建通道时生效")
            return
        }
        if (_isScenarioUpdating.value) return
        // Bug2:升档(需要之前没加载的 MT/TTS)前做就绪预检;未就绪则弹下载确认框,不调 SDK、不只 toast。
        val upgrading = (option.needMt && !_scenarioOption.value.needMt) ||
            (option.needTts && !_scenarioOption.value.needTts)
        if (upgrading && !TmkTranslationSDK.isOfflineModelReady(
                srcLang = _sourceLang.value,
                dstLang = _targetLang.value,
                scenario = Scenario.LISTEN,
                needMt = option.needMt,
                needTts = option.needTts,
            )
        ) {
            // 升档不改语言、也不提前改 UI 档位(_scenarioOption 保持旧值,直到 updateScenario onSuccess 才落地)。
            // 下载按目标档位的 needMt/needTts 下差量包,故把目标档位存进 PendingDownloadInfo.targetScenario 供 downloadModels 取用。
            _pendingDownloadPrompt.value = buildPendingDownloadInfo(_sourceLang.value, _targetLang.value, option, upgrade = true)
            addLog("升档所需模型未就绪,已弹出下载确认")
            return
        }
        _isScenarioUpdating.value = true
        addLog("正在切换能力为${option.title}...")
        currentChannel.updateScenario(
            scenario = option.roomScenario,
            callback = object : ActionCallback {
                override fun onSuccess(result: Result<Unit>) {
                    _scenarioOption.value = option
                    _isScenarioUpdating.value = false
                    refreshModelReady()
                    addLog("能力切换成功: ${option.title}(${option.roomScenario.value})")
                }

                override fun onError(errorId: Int, e: Exception) {
                    _isScenarioUpdating.value = false
                    addLog("能力切换失败: [$errorId] ${e.message}")
                    _localeSwitchError.value = "能力切换失败: ${e.message}"
                }
            }
        )
    }
    private val _speakerGender = MutableStateFlow(SpeakerGender.FEMALE)
    val speakerGender: StateFlow<SpeakerGender> = _speakerGender.asStateFlow()
    private val _isLocaleUpdating = MutableStateFlow(false)
    val isLocaleUpdating: StateFlow<Boolean> = _isLocaleUpdating.asStateFlow()
    // 语言切换失败的一次性轻量提示(Toast);Screen 消费后调 consumeLocaleSwitchError() 清空。
    // 切语言失败不影响当前正在运行的通道,故用 Toast 而非重型的通道异常弹窗(那会触发重建/退出)。
    private val _localeSwitchError = MutableStateFlow<String?>(null)
    val localeSwitchError: StateFlow<String?> = _localeSwitchError.asStateFlow()
    private var hasLockedLanguages = false

    // Bug2:切语言/升档前就绪预检未通过时的待下载确认弹窗状态(null=不显示)。
    private val _pendingDownloadPrompt = MutableStateFlow<PendingDownloadInfo?>(null)
    val pendingDownloadPrompt: StateFlow<PendingDownloadInfo?> = _pendingDownloadPrompt.asStateFlow()

    // Bug2:模型下载完成后提示用户手动重试切换的一次性文案(不自动重试);Screen 消费后清空。
    private val _retryHintAfterDownload = MutableStateFlow<String?>(null)
    val retryHintAfterDownload: StateFlow<String?> = _retryHintAfterDownload.asStateFlow()

    // 本次下载若来自引导(切语言/升档触发的确认弹窗),在 confirmPendingDownload 里按来源预置好完整重试文案;
    // 普通"下载当前语言模型"按钮/自动补下载则保持 null。下载完成回调据此提示,且只提示一次(用后清空)。
    // 对齐 iOS 的 isGuidedDownload + guidedDownloadIsUpgrade 语义:非引导下载完成不提示"重试切换"。
    private var guidedDownloadHint: String? = null

    // Bug3:按字节的全局下载总进度(0..1),由 SDK onOfflineModelTotalProgress 回调驱动,供卡片总进度条使用。
    private val _totalDownloadProgress = MutableStateFlow(0f)
    val totalDownloadProgress: StateFlow<Float> = _totalDownloadProgress.asStateFlow()

    fun setLanguagesIfNeeded(sourceLang: String, targetLang: String) {
        if (hasLockedLanguages) return
        _sourceLang.value = sourceLang
        _targetLang.value = targetLang
        hasLockedLanguages = true
        if (_offlineSupportChecked.value && _isOfflineSupported.value) {
            refreshModelReady()
        }
    }

    private fun refreshModelReady() {
        if (!_isOfflineSupported.value) {
            _offlineModelPackages.value = emptyList()
            _isModelReady.value = false
            return
        }
        val packages = TmkTranslationSDK.getOfflineModelPackageInfos(
            context = application,
            srcLang = _sourceLang.value,
            dstLang = _targetLang.value,
            scenario = Scenario.LISTEN,
            needMt = _scenarioOption.value.needMt,
            needTts = _scenarioOption.value.needTts,
        )
        _offlineModelPackages.value = packages
        _isModelReady.value = packages.isNotEmpty() && packages.all { it.state == TmkOfflineModelPackageState.READY }
    }

    private fun addLog(msg: String) {
        Log.d(TAG, msg)
        _logMessages.value = listOf(msg) + _logMessages.value.take(99)
    }

    // 请求刷新气泡:仅投递一个合并请求(CONFLATED,不阻塞、不堆积),真正的重算在后台协程去抖后进行。
    // 不再在调用线程(主线程回调)同步做全量 snapshotWithSegments(),消除长时间运行的主线程卡顿。
    private fun publishBubbles() { bubbleRefreshRequests.trySend(Unit) }

    private fun showConversationErrorPrompt(prompt: OnlineConversationErrorPrompt?) {
        if (prompt == null || _conversationErrorPrompt.value?.id == prompt.id) return
        _conversationErrorPrompt.value = prompt
    }

    private fun applySdkChannelSnapshot(snapshot: TmkTranslationChannelStateSnapshot) {
        when (snapshot.state) {
            TmkTranslationChannelState.STARTING -> {
                _isStarting.value = true
                _isChannelReady.value = false
            }
            TmkTranslationChannelState.RUNNING -> {
                _isStarting.value = false
                _isChannelReady.value = true
                addLog("离线通道已就绪，可以开始收听")
            }
            TmkTranslationChannelState.STOPPING -> {
                _isChannelReady.value = false
                if (_isStarted.value) stopListening()
            }
            TmkTranslationChannelState.STOPPED -> {
                _isStarting.value = false
                _isChannelReady.value = false
                if (_isStarted.value) stopListening()
            }
            TmkTranslationChannelState.FAILED -> {
                _isStarting.value = false
                _isChannelReady.value = false
                if (_isStarted.value) stopListening()
                addLog("通道异常: ${snapshot.message}")
                showConversationErrorPrompt(
                    OnlineConversationErrorPrompts.fromSnapshot(
                        snapshot,
                        OnlineConversationErrorPrompts.RuntimeMode.OFFLINE,
                    )
                )
            }
            TmkTranslationChannelState.IDLE -> {
                _isStarting.value = false
                _isChannelReady.value = false
            }
            TmkTranslationChannelState.RECONNECTING,
            TmkTranslationChannelState.DEGRADED -> Unit
        }
    }

    private fun buildTraceMetadata(channel: Int): Pair<ByteArray, String> {
        val now = java.util.Calendar.getInstance()
        val hour = now.get(java.util.Calendar.HOUR_OF_DAY)
        val minute = now.get(java.util.Calendar.MINUTE)
        val second = now.get(java.util.Calendar.SECOND)
        val metadata = byteArrayOf(channel.toByte(), hour.toByte(), minute.toByte(), second.toByte())
        val traceId = String.format(java.util.Locale.US, "%d%02d%02d%02d", channel, hour, minute, second)
        return metadata to traceId
    }

    private fun resetTrace() {
        currentTraceId = null; pendingMetadata = null; vadStartMs = 0; firstAsrMs = 0; firstMtMs = 0; firstTtsMs = 0
    }

    fun downloadModels(
        scenarioForPackages: OfflineScenarioOption = _scenarioOption.value,
        srcForPackages: String = _sourceLang.value,
        dstForPackages: String = _targetLang.value,
        isGuided: Boolean = false,
    ) {
        if (_isDownloading.value) return
        // 非引导下载(普通"下载当前语言模型"按钮/自动补下载)不提示"重试切换";清掉上次残留的引导文案。
        // 引导下载由 confirmPendingDownload 先设好 guidedDownloadHint 再以 isGuided=true 调入,故此处不清。
        if (!isGuided) guidedDownloadHint = null
        released = false
        userCancelledDownload = false
        if (!_offlineSupportChecked.value) {
            verifyAuthThenRefreshOfflineState(autoStartIfReady = false, autoDownloadIfNeeded = true)
            return
        }
        if (!_isOfflineSupported.value) {
            applyOfflineUnsupportedState()
            return
        }
        _isDownloading.value = true
        _downloadProgress.value = "准备下载..."
        _totalDownloadProgress.value = 0f
        addLog("开始下载 ${TranslationLanguages.displayName(srcForPackages)} → ${TranslationLanguages.displayName(dstForPackages)} 模型...")

        var lastLoggedPct = -1L
        TmkTranslationSDK.downloadOfflineModels(
            context = application,
            srcLang = srcForPackages,
            dstLang = dstForPackages,
            scenario = Scenario.LISTEN,
            needMt = scenarioForPackages.needMt,
            needTts = scenarioForPackages.needTts,
            listener = object : TmkOfflineModelDownloadListener {
                override fun onOfflineModelDownloadProgress(
                    fileName: String,
                    index: Int,
                    total: Int,
                    downloaded: Long,
                    fileTotal: Long,
                ) {
                    if (userCancelledDownload) return
                    val pct = if (fileTotal > 0) (downloaded * 100 / fileTotal) else 0
                    _downloadProgress.value = "($index/$total) $fileName ${pct}%"
                    if (pct >= lastLoggedPct + 5) {
                        lastLoggedPct = pct
                        addLog("[$fileName] $pct%")
                    }
                }

                override fun onOfflineModelUnzipProgress(fileName: String, progress: Double) {
                    if (userCancelledDownload) return
                    _downloadProgress.value = "$fileName 解压中 ${(progress * 100).toInt()}%"
                }

                // Bug3:全局总进度(按字节)。totalBytesAll 可能为 0(所有 HEAD 失败),此时保持 0 待实时字节补齐。
                override fun onOfflineModelTotalProgress(downloadedBytesAll: Long, totalBytesAll: Long) {
                    if (userCancelledDownload) return
                    _totalDownloadProgress.value = if (totalBytesAll > 0L) {
                        (downloadedBytesAll.toFloat() / totalBytesAll.toFloat()).coerceIn(0f, 1f)
                    } else {
                        0f
                    }
                }

                override fun onOfflineModelReady() {
                    if (released || userCancelledDownload) return
                    addLog("模型下载完成")
                    _downloadProgress.value = "下载完成"
                    _totalDownloadProgress.value = 1f
                    _isDownloading.value = false
                    refreshModelReady()
                    // Bug2:下载完成不自动重试。仅引导下载(切语言/升档)提示手动重试,文案按来源在 guidedDownloadHint 里已区分
                    // (升档→重试切换能力,切语言→重试切换语言);普通/自动下载 guidedDownloadHint 为 null,不提示。用后清空(一次性)。
                    _retryHintAfterDownload.value = guidedDownloadHint
                    guidedDownloadHint = null
                    if (_isModelReady.value) {
                        prepareChannelIfNeeded()
                    }
                }

                override fun onOfflineModelPackageInfosChanged(packages: List<TmkOfflineModelPackageInfo>) {
                    if (released || userCancelledDownload) return
                    _offlineModelPackages.value = packages
                    _isModelReady.value = packages.isNotEmpty() && packages.all { it.state == TmkOfflineModelPackageState.READY }
                }

                override fun onOfflineModelEvent(name: String, args: Any?) {
                    if (released) return
                    if (name == "offline_model_cancelled") {
                        userCancelledDownload = true
                        _downloadProgress.value = "下载已取消"
                        _isDownloading.value = false
                        // 取消属终止路径,显式清空引导重试提示(仅成功路径消费,失败/取消不再提示)。
                        guidedDownloadHint = null
                        refreshModelReady()
                    } else if (name == "offline_model_update_required") {
                        _downloadProgress.value = "模型需要更新"
                        refreshModelReady()
                    }
                }

                override fun onOfflineModelError(code: Int, message: String) {
                    if (released || userCancelledDownload) return
                    addLog("下载失败: [$code] $message")
                    showConversationErrorPrompt(
                        OnlineConversationErrorPrompts.fromCode(
                            code,
                            message,
                            mode = OnlineConversationErrorPrompts.RuntimeMode.OFFLINE,
                        )
                    )
                    _downloadProgress.value = "下载失败"
                    _isDownloading.value = false
                    // 下载失败属终止路径,显式清空引导重试提示(仅成功路径消费,失败/取消不再提示)。
                    guidedDownloadHint = null
                    refreshModelReady()
                }
            },
        )
    }

    fun cancelDownloadModels() {
        if (!_isDownloading.value) return
        userCancelledDownload = true
        TmkTranslationSDK.cancelOfflineModelDownload()
        _isDownloading.value = false
        _downloadProgress.value = "下载已取消"
        // 主动取消属终止路径,显式清空引导重试提示(仅成功路径消费,失败/取消不再提示)。
        guidedDownloadHint = null
        refreshModelReady()
        addLog("已取消离线模型下载")
    }

    fun initSDK() {
        released = false
        verifyAuthThenRefreshOfflineState(autoStartIfReady = true)
    }

    private fun ensureSdkInitialized(): Boolean {
        return try {
            if (!_isInitialized.value) {
                TmkTranslationSDK.sdkInit(application, SampleSdkConfig.globalConfig(application))
                TmkTranslationSDK.lingCastTelemetrySetTraceReportingEnabled(true)
                _isInitialized.value = true
                _initErrorMessage.value = null
                addLog("SDK 初始化完成")
            }
            true
        } catch (e: Exception) {
            addLog("SDK 初始化异常: ${e.message}")
            _initErrorMessage.value = SampleSdkConfig.buildInitErrorMessage(e)
            Log.e(TAG, "initSDK failed", e)
            false
        }
    }

    fun dismissInitError() {
        _initErrorMessage.value = null
    }

    private fun verifyAuthThenRefreshOfflineState(
        autoStartIfReady: Boolean,
        autoDownloadIfNeeded: Boolean = false,
    ) {
        if (!ensureSdkInitialized()) return
        if (_isCheckingOfflineSupport.value) return
        _isCheckingOfflineSupport.value = true
        addLog("开始鉴权并检查离线能力...")
        try {
            TmkTranslationSDK.verifyAuth(object : AuthCallback {
                override fun onSuccess() {
                    if (released) {
                        _isCheckingOfflineSupport.value = false
                        return
                    }
                    _offlineSupportChecked.value = true
                    _isOfflineSupported.value = TmkTranslationSDK.isOfflineTranslationSupported()
                    _isCheckingOfflineSupport.value = false
                    if (!_isOfflineSupported.value) {
                        applyOfflineUnsupportedState()
                        return
                    }
                    addLog("鉴权成功，当前账号支持离线翻译")
                    refreshModelReady()
                    if (_isModelReady.value) {
                        if (autoStartIfReady) prepareChannelIfNeeded()
                    } else {
                        addLog("当前模型资源不完整，需要先下载离线资源")
                        if (autoDownloadIfNeeded) downloadModels()
                    }
                }

                override fun onError(errorId: Int, e: Exception) {
                    _offlineSupportChecked.value = false
                    _isOfflineSupported.value = false
                    _isCheckingOfflineSupport.value = false
                    _isModelReady.value = false
                    _offlineModelPackages.value = emptyList()
                    addLog("鉴权失败: [$errorId] ${e.message}")
                    showConversationErrorPrompt(
                        OnlineConversationErrorPrompts.fromCode(
                            errorId,
                            e.message ?: "offline auth failed",
                            mode = OnlineConversationErrorPrompts.RuntimeMode.OFFLINE,
                        )
                    )
                }
            })
        } catch (e: Exception) {
            _offlineSupportChecked.value = false
            _isOfflineSupported.value = false
            _isCheckingOfflineSupport.value = false
            _isModelReady.value = false
            _offlineModelPackages.value = emptyList()
            addLog("鉴权异常: ${e.message}")
            Log.e(TAG, "verifyAuth failed", e)
        }
    }

    private fun applyOfflineUnsupportedState() {
        TmkTranslationSDK.releaseChannel()
        channel = null
        _isChannelReady.value = false
        _isStarting.value = false
        _isStarted.value = false
        _isDownloading.value = false
        _downloadProgress.value = ""
        _offlineModelPackages.value = emptyList()
        _isModelReady.value = false
        addLog("当前账号未开通离线翻译能力")
        showConversationErrorPrompt(
            OnlineConversationErrorPrompts.fromCode(
                TmkTranslationException.ErrorCodes.OFFLINE_MODEL_NOT_READY,
                "当前账号未开通离线翻译能力",
                mode = OnlineConversationErrorPrompts.RuntimeMode.OFFLINE,
            )
        )
    }

    fun start() {
        if (!_isInitialized.value || channel == null || !_isChannelReady.value) {
            addLog("离线通道未就绪，尝试重新准备")
            initSDK()
            return
        }
        if (_isStarted.value) return
        if (!startRecording()) return
        _isStarted.value = true
        addLog("离线收听已开始采集")
    }

    private fun prepareChannelIfNeeded() {
        // 退出竞态守卫:已退出(released)时不建房,仅拦退出后残留异步回调触发的重建;正常进入不受影响。
        if (released) return
        if (channel != null || _isStarting.value) return
        if (!_isOfflineSupported.value) {
            applyOfflineUnsupportedState()
            return
        }
        if (OfflineDemoModelReadinessPolicy.shouldRefreshBeforePreparingChannel(_isModelReady.value)) {
            refreshModelReady()
        }
        if (!_isModelReady.value) {
            addLog("当前模型资源不完整，需要先下载离线资源")
            return
        }
        released = false
        _isStarting.value = true
        doStart()
    }

    private fun doStart() {
        addLog("创建离线翻译通道...")

        try {
            TmkTranslationSDK.createTmkTranslationRoom(object : CreateRoomCallback {
                override fun onSuccess(room: TmkTranslationRoom) {
                    if (released) { _isStarting.value = false; return }
                    addLog("创建房间成功: ${room.roomId}")

                    try {
                        // 构建模型路径
                        val modelRootDir = TmkTranslationSDK.defaultOfflineModelRootDirectory(application)

                        val channelConfig = TmkTransChannelConfig.Builder()
                            .setRoom(room)
                            .setMode(TranslationMode.OFFLINE)
                            .setScenario(Scenario.LISTEN)
                            .setTransModeType(TransModeType.LISTEN)
                            .setSourceLang(_sourceLang.value)
                            .setTargetLang(_targetLang.value)
                            .setSpeakers(listOf(TmkSpeaker(SpeakerChannel.LEFT, _speakerGender.value)))
                            .setSampleRate(SAMPLE_RATE)
                            .setChannelNum(1)
                            .setModelRootDirectory(modelRootDir)
                            // 离线 Demo 显式开启中间态下发(D1:不设则默认 stable 看不到 MT 中间态)。
                            .setTranslateMode(_translateMode.value)
                            // 能力档位(三档对齐在线):按需加载,recognize 只建 ASR、s2t 建 ASR+MT、s2s 全建。
                            .setRoomScenario(_scenarioOption.value.roomScenario)
                            .build()

                        addLog("src=${_sourceLang.value} tgt=${_targetLang.value} modelRootDirectory: $modelRootDir")

                        TmkTranslationSDK.createTranslationChannel(
                            application,
                            channelConfig,
                            translationListener,
                            object : CreateChannelCallback {
                                override fun onSuccess(ch: TmkTranslationChannel) {
                                    if (released) {
                                        TmkTranslationSDK.releaseChannel()
                                        _isStarting.value = false
                                        return
                                    }
                                    try {
                                        channel = ch
                                        addLog("创建离线 Channel 成功")
                                        _isStarting.value = false
                                        _isChannelReady.value = true
                                    } catch (e: Exception) {
                                        addLog("启动离线 Channel 异常: ${e.message}")
                                        Log.e(TAG, "start channel failed", e)
                                        channel = null
                                        _isChannelReady.value = false
                                        _isStarting.value = false
                                    }
                                }

                                override fun onError(errorId: Int, e: Exception) {
                                    addLog("创建 Channel 失败: [$errorId] ${e.message}")
                                    _isStarting.value = false
                                    showConversationErrorPrompt(
                                        OnlineConversationErrorPrompts.fromCode(
                                            errorId,
                                            e.message ?: "create offline channel failed",
                                            mode = OnlineConversationErrorPrompts.RuntimeMode.OFFLINE,
                                        )
                                    )
                                }
                            }
                        )
                    } catch (e: Exception) {
                        addLog("创建 Channel 异常: ${e.message}")
                        Log.e(TAG, "createTranslationChannel failed", e)
                        _isStarting.value = false
                    }
                }

                override fun onError(errorId: Int, e: Exception) {
                    addLog("创建房间失败: [$errorId] ${e.message}")
                    _isStarting.value = false
                }
            })
        } catch (e: Exception) {
            addLog("创建房间异常: ${e.message}")
            Log.e(TAG, "createTmkTranslationRoom failed", e)
            _isStarting.value = false
        }
    }

    fun stopListening() {
        stopRecording()
        stopTtsPlayback()
        _isStarted.value = false
        addLog("离线收听已停止采集")
    }

    fun stop() {
        released = true
        if (_isDownloading.value) {
            userCancelledDownload = true
            TmkTranslationSDK.cancelOfflineModelDownload()
            _isDownloading.value = false
            _downloadProgress.value = ""
        }
        speakerCancelable?.cancel()
        speakerCancelable = null
        localeCancelable?.cancel()
        localeCancelable = null
        _isLocaleUpdating.value = false
        stopListening()
        TmkTranslationSDK.releaseChannel()
        channel = null
        _isChannelReady.value = false
        _isStarting.value = false
        _isStarted.value = false
        _conversationErrorPrompt.value = null
        addLog("离线翻译已停止")
    }

    fun recreateChannelAfterRuntimeFailure() {
        _conversationErrorPrompt.value = null
        stop()
        released = false
        initSDK()
    }

    fun dismissConversationErrorPrompt() {
        _conversationErrorPrompt.value = null
    }

    /**
     * 运行时切换收听语言（离线单向 source → target）。
     *
     * - 通道未就绪(channel==null 或 !_isChannelReady):仅更新 UI 语言,离线重建通道(doStart)时会读取
     *   最新的 _sourceLang/_targetLang 自然生效,故无需 pending 机制。
     * - 通道就绪:调用 channel.updateLanguages 运行时切(离线走销毁重建三段模型),成功后才回写 UI。
     * - _isLocaleUpdating 防并发下发。
     */
    fun updateLanguages(sourceLang: String, targetLang: String) {
        val currentChannel = channel
        if (currentChannel == null || !_isChannelReady.value) {
            // 通道未就绪:更新语言,离线重建通道时以最新 _sourceLang/_targetLang 生效。
            _sourceLang.value = sourceLang
            _targetLang.value = targetLang
            // 语言变化后模型资源需求随之变化,刷新就绪状态。
            if (_offlineSupportChecked.value && _isOfflineSupported.value) {
                refreshModelReady()
            }
            addLog("语言已保存为 ${TranslationLanguages.displayName(sourceLang)} → ${TranslationLanguages.displayName(targetLang)},将在通道就绪后生效")
            return
        }
        if (_isLocaleUpdating.value) {
            addLog("正在切换语言,请稍候...")
            return
        }
        // Bug2:切语言前按当前档位(needMt/needTts)+ LISTEN + 目标语言对做就绪预检。
        // 未就绪则不下发 SDK,弹确认框引导下载;就绪才真正 updateLanguages。
        if (!isTargetPairReady(sourceLang, targetLang)) {
            _pendingDownloadPrompt.value = buildPendingDownloadInfo(sourceLang, targetLang, _scenarioOption.value, upgrade = false)
            addLog("目标语言模型未就绪,已弹出下载确认")
            return
        }
        _isLocaleUpdating.value = true
        addLog("正在切换语言为 ${TranslationLanguages.displayName(sourceLang)} → ${TranslationLanguages.displayName(targetLang)}...")
        localeCancelable?.cancel()
        localeCancelable = currentChannel.updateLanguages(
            sourceLang,
            targetLang,
            object : ActionCallback {
                override fun onSuccess(result: Result<Unit>) {
                    _sourceLang.value = sourceLang
                    _targetLang.value = targetLang
                    _isLocaleUpdating.value = false
                    if (_offlineSupportChecked.value && _isOfflineSupported.value) {
                        refreshModelReady()
                    }
                    addLog("语言切换成功: ${TranslationLanguages.displayName(sourceLang)} → ${TranslationLanguages.displayName(targetLang)},下一句话生效")
                }

                override fun onError(errorId: Int, e: Exception) {
                    _isLocaleUpdating.value = false
                    val msg = e.message ?: "switch language failed"
                    addLog("语言切换失败: [$errorId] $msg")
                    showLanguageSwitchErrorPrompt(errorId, sourceLang, targetLang, msg)
                }
            }
        )
    }

    /**
     * 语言切换失败时给一次性轻量提示(Toast)。切语言失败不影响当前正在运行的通道,
     * 故不复用会触发重建/退出的通道异常弹窗;仅提示原因,用户可重新下载模型或重选语言。
     * - OFFLINE_MODEL_NOT_READY:明确提示先下载对应语言模型再切换。
     * - 其它错误码:通用文案。
     */
    private fun showLanguageSwitchErrorPrompt(
        errorId: Int,
        sourceLang: String,
        targetLang: String,
        message: String,
    ) {
        _localeSwitchError.value = if (errorId == TmkTranslationException.ErrorCodes.OFFLINE_MODEL_NOT_READY) {
            "离线模型未就绪，请先下载 ${TranslationLanguages.displayName(sourceLang)} → ${TranslationLanguages.displayName(targetLang)} 语言模型后再切换"
        } else {
            "语言切换失败: [$errorId] $message"
        }
    }

    /** Screen 弹出 Toast 后调用,清空一次性提示,避免重组重复弹。 */
    fun consumeLocaleSwitchError() {
        _localeSwitchError.value = null
    }

    /**
     * Bug2:按当前档位 + LISTEN + 指定语言对做就绪预检(不改变当前 UI 语言)。
     * 复用 refreshModelReady 同款 SDK 就绪检查,scenario 固定 LISTEN(收听单向)。
     */
    private fun isTargetPairReady(sourceLang: String, targetLang: String): Boolean {
        return TmkTranslationSDK.isOfflineModelReady(
            srcLang = sourceLang,
            dstLang = targetLang,
            scenario = Scenario.LISTEN,
            needMt = _scenarioOption.value.needMt,
            needTts = _scenarioOption.value.needTts,
        )
    }

    /** Bug2:构造待下载确认弹窗信息(目标语言对 + 目标档位的人类可读说明)。
     *  升档传目标档位 option,切语言传当前 _scenarioOption.value(档位不变);downloadModels 按 targetScenario 下差量包。 */
    private fun buildPendingDownloadInfo(
        sourceLang: String,
        targetLang: String,
        targetScenario: OfflineScenarioOption,
        upgrade: Boolean,
    ): PendingDownloadInfo {
        val pair = "${TranslationLanguages.displayName(sourceLang)} → ${TranslationLanguages.displayName(targetLang)}"
        val action = if (upgrade) "切换到「${targetScenario.title}」档位" else "切换到 $pair"
        return PendingDownloadInfo(
            sourceLang = sourceLang,
            targetLang = targetLang,
            targetScenario = targetScenario,
            description = "$action 所需的离线模型($pair,${targetScenario.title})尚未就绪,是否现在下载?下载完成后请手动重试。",
            upgrade = upgrade,
        )
    }

    /**
     * Bug2:用户在确认弹窗点「下载」。清弹窗后按目标语言对/目标档位下所需差量包,
     * 但不改 UI 语言 StateFlow(也不改 _scenarioOption UI 档位):下载期间页面仍显示旧语言对,
     * 直到用户手动重试切语言且 updateLanguages 成功后才落地新语言。下载完成回调里提示手动重试,不自动重试。
     */
    fun confirmPendingDownload() {
        val info = _pendingDownloadPrompt.value ?: return
        _pendingDownloadPrompt.value = null
        addLog("开始下载缺失模型(${info.description})")
        // 记录本次为引导下载,并按来源预置完成后的重试文案:升档→重试切换能力,切语言→重试切换语言。
        guidedDownloadHint = if (info.upgrade) {
            "下载完成,请重试切换能力"
        } else {
            "下载完成,请重试切换语言"
        }
        // 切语言:用 info 里的目标语言对下包但不改 UI 语言;升档:info 语言=当前语言、targetScenario 即当前档位,行为不变。
        downloadModels(
            scenarioForPackages = info.targetScenario,
            srcForPackages = info.sourceLang,
            dstForPackages = info.targetLang,
            isGuided = true,
        )
    }

    /** Bug2:用户在确认弹窗点「取消」。清弹窗 + 提示当前语言未切换。 */
    fun cancelPendingDownload() {
        _pendingDownloadPrompt.value = null
        _localeSwitchError.value = "已取消,当前语言未切换"
        addLog("已取消下载,当前语言未切换")
    }

    /** Screen 消费「下载完成请重试」提示后清空。 */
    fun consumeRetryHintAfterDownload() {
        _retryHintAfterDownload.value = null
    }

    fun updateSpeaker(gender: SpeakerGender) {
        _speakerGender.value = gender
        val currentChannel = channel
        if (currentChannel == null) {
            addLog("音色已设置为${speakerLabel(gender)}，将在创建离线通道时生效")
            return
        }
        speakerCancelable?.cancel()
        speakerCancelable = currentChannel.updateSpeaker(
            listOf(TmkSpeaker(SpeakerChannel.LEFT, gender)),
            object : ActionCallback {
                override fun onSuccess(result: Result<Unit>) {
                    addLog("音色设置成功: ${speakerLabel(gender)}，下一次 TTS 生效")
                }

                override fun onError(errorId: Int, e: Exception) {
                    addLog("音色设置失败: [$errorId] ${e.message}")
                }
            }
        )
    }

    private fun speakerLabel(gender: SpeakerGender): String = when (gender) {
        SpeakerGender.MALE -> "男声"
        SpeakerGender.FEMALE -> "女声"
    }

    private val translationListener = object : TmkTranslationListener {
        override fun onRecognized(fromEngine: AbstractChannelEngine?, r: co.timekettle.translation.model.Result<String>?, isFinal: Boolean) {
            Log.d(TAG, DemoTmkResultLogFormatter.makeLine("OfflineListen", "ASR", r, isFinal))
            val text = r?.data ?: ""
            val src = r?.srcCode?.takeIf { it.isNotEmpty() } ?: _sourceLang.value
            val dst = r?.dstCode?.takeIf { it.isNotEmpty() } ?: _targetLang.value
            DemoConversationEventAdapter.makeRecognizedEvent(r, isFinal, src, dst)?.let { bubbleAssembler.consume(it) }
            publishBubbles()
            val tid = currentTraceId
            if (isFinal && tid != null && firstAsrMs == 0L) {
                firstAsrMs = System.currentTimeMillis()
                addLog("ASR [final]: $text | traceId=$tid ASR=${firstAsrMs - vadStartMs}ms")
            } else {
                addLog("ASR [final=$isFinal]: $text")
            }
        }

        override fun onTranslate(fromEngine: AbstractChannelEngine?, r: co.timekettle.translation.model.Result<String>?, isFinal: Boolean) {
            Log.d(TAG, DemoTmkResultLogFormatter.makeLine("OfflineListen", "MT", r, isFinal))
            val text = r?.data ?: ""
            val src = r?.srcCode?.takeIf { it.isNotEmpty() } ?: _sourceLang.value
            val dst = r?.dstCode?.takeIf { it.isNotEmpty() } ?: _targetLang.value
            DemoConversationEventAdapter.makeTranslatedEvent(r, isFinal, src, dst)?.let { bubbleAssembler.consume(it) }
            publishBubbles()
            val tid = currentTraceId
            if (isFinal && tid != null && firstMtMs == 0L) {
                firstMtMs = System.currentTimeMillis()
                addLog("MT [final]: $text | traceId=$tid MT=${firstMtMs - vadStartMs}ms")
            } else {
                addLog("MT [final=$isFinal]: $text")
            }
        }

        override fun onAudioDataReceive(fromEngine: AbstractChannelEngine?, r: co.timekettle.translation.model.Result<String>?, data: ByteArray, channelCount: Int) {
            val tid = currentTraceId
            if (tid != null && firstTtsMs == 0L && data.isNotEmpty()) {
                firstTtsMs = System.currentTimeMillis()
                val total = firstTtsMs - vadStartMs
                val asr = if (firstAsrMs > 0) firstAsrMs - vadStartMs else -1
                val mt = if (firstMtMs > 0) firstMtMs - vadStartMs else -1
                addLog("TTS 首包 | traceId=$tid 总=${total}ms ASR=${asr}ms MT=${mt}ms")
            }
            playTtsAudio(data, resolveTtsSampleRate(r), channelCount)
        }

        override fun onError(code: Int, msg: String) {
            addLog("Error [$code]: $msg")
            showConversationErrorPrompt(
                OnlineConversationErrorPrompts.fromCode(
                    code,
                    msg,
                    mode = OnlineConversationErrorPrompts.RuntimeMode.OFFLINE,
                )
            )
        }
        override fun onEvent(eventName: String, args: Any?) {
            if (eventName == "offline_bubble_end") {
                val result = args as? Result<*> ?: return
                val bubbleId = result.bubbleId.takeIf { it.isNotBlank() }
                    ?: result.extraData?.get("bubble_id")?.toString()?.takeIf { it.isNotBlank() }
                    ?: return
                val affectedRows = bubbleAssembler.markBubbleEnded(bubbleId)
                Log.d(TAG, DemoTmkResultLogFormatter.makeBubbleEndLine("OfflineListen", result, affectedRows.size))
                publishBubbles()
                return
            }
            addLog("Event: $eventName")
        }
        override fun onStateChanged(fromEngine: AbstractChannelEngine?, snapshot: TmkTranslationChannelStateSnapshot) {
            addLog("状态变化: ${snapshot.state.rawValue}/${snapshot.reason.rawValue} ${snapshot.message}")
            applySdkChannelSnapshot(snapshot)
        }
    }

    private fun startRecording(): Boolean {
        if (isRecording) return true
        if (ContextCompat.checkSelfPermission(application, Manifest.permission.RECORD_AUDIO)
            != PackageManager.PERMISSION_GRANTED
        ) {
            addLog("没有录音权限")
            return false
        }
        val bufferSize = AudioRecord.getMinBufferSize(
            SAMPLE_RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT
        )
        audioRecord = AudioRecord(
            MediaRecorder.AudioSource.MIC, SAMPLE_RATE,
            AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT, bufferSize
        )
        isRecording = true
        audioRecord?.startRecording()
        addLog("录音已开始")

        vadDetector = VadDetector(sampleRate = SAMPLE_RATE).apply {
            setCallback(object : VadDetector.Callback {
                override fun onVadStart() {
                    resetTrace()
                    val (metadata, traceId) = buildTraceMetadata(channel = 1)
                    pendingMetadata = metadata
                    currentTraceId = traceId
                    TmkTranslationSDK.lingCastTelemetryStartTrace(traceId)
                    vadStartMs = System.currentTimeMillis() - (vadDetector?.getVadBeginDurationMs() ?: 0)
                    addLog("VAD → 开始说话 traceId=$currentTraceId")
                }
                override fun onVadEnd() {
                    val tid = currentTraceId ?: return
                    addLog("VAD → 停止说话 traceId=$tid 持续${System.currentTimeMillis() - vadStartMs}ms")
                }
            })
            init()
        }

        Thread {
            val buffer = ByteArray(bufferSize)
            while (isRecording) {
                val read = audioRecord?.read(buffer, 0, buffer.size) ?: -1
                if (read > 0) {
                    val data = buffer.copyOf(read)
                    vadDetector?.pushAudioBytes(data)
                    val metadata = pendingMetadata
                    pendingMetadata = null
                    channel?.pushStreamAudioData(data, 1, metadata)
                }
            }
        }.start()
        return true
    }

    private fun stopRecording() {
        isRecording = false
        vadDetector?.release(); vadDetector = null
        try {
            audioRecord?.stop()
            audioRecord?.release()
        } catch (_: Exception) {}
        audioRecord = null
    }

    private fun playTtsAudio(data: ByteArray, sampleRate: Int, channelCount: Int) {
        if (data.isEmpty()) return
        val safeSampleRate = sampleRate.takeIf { it > 0 } ?: SAMPLE_RATE
        val safeChannelCount = if (channelCount == 2) 2 else 1
        synchronized(ttsQueueLock) {
            if ((queuedTtsSampleRate != 0 && queuedTtsSampleRate != safeSampleRate) ||
                (queuedTtsChannelCount != 0 && queuedTtsChannelCount != safeChannelCount)
            ) {
                clearTtsQueueLocked()
            }
            queuedTtsSampleRate = safeSampleRate
            queuedTtsChannelCount = safeChannelCount
            ensureTtsPlayerThreadLocked()
            ttsQueue.addLast(TtsFrame(data.copyOf(), safeSampleRate, safeChannelCount))
            ttsQueuedBytes += data.size
            trimTtsQueueLocked(safeSampleRate, safeChannelCount)
            ttsQueueLock.notifyAll()
        }
    }

    private fun ensureTtsPlayerThreadLocked() {
        if (isTtsPlayerRunning && ttsPlayerThread?.isAlive == true) return
        isTtsPlayerRunning = true
        ttsPlayerThread = Thread({ runTtsPlaybackLoop() }, "$TAG-TtsPlayer").apply { start() }
    }

    private fun runTtsPlaybackLoop() {
        while (isTtsPlayerRunning) {
            val frame = synchronized(ttsQueueLock) {
                while (ttsQueue.isEmpty() && isTtsPlayerRunning) {
                    try {
                        ttsQueueLock.wait()
                    } catch (_: InterruptedException) {
                    }
                }
                if (!isTtsPlayerRunning) {
                    null
                } else {
                    val next = ttsQueue.removeFirst()
                    ttsQueuedBytes -= next.data.size
                    if (ttsQueue.isEmpty()) {
                        queuedTtsSampleRate = 0
                        queuedTtsChannelCount = 0
                    }
                    next
                }
            } ?: break
            writeTtsFrame(frame)
        }
    }

    private fun writeTtsFrame(frame: TtsFrame) {
        try {
            val track = ensureTtsAudioTrack(frame.sampleRate, frame.channelCount) ?: return
            var offset = 0
            while (offset < frame.data.size && isTtsPlayerRunning) {
                val written = track.write(frame.data, offset, frame.data.size - offset)
                if (written > 0) {
                    offset += written
                } else if (written < 0) {
                    // bug 7051627151: AudioTrack 进入错误状态时（written < 0），
                    // 强制释放后退出，让下一帧 ensureTtsAudioTrack 重建一个干净的实例，
                    // 避免 track 一直处于 ERROR 状态导致 TTS 静默或潜在阻塞。
                    Log.e(TAG, "播放 TTS 写入失败 error=$written，强制重建 AudioTrack")
                    releaseTtsAudioTrack()
                    break
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "播放 TTS 异常", e)
        }
    }

    private fun ensureTtsAudioTrack(sampleRate: Int, channelCount: Int): AudioTrack? {
        val safeChannelCount = if (channelCount == 2) 2 else 1
        val existing = audioTrack
        if (existing != null &&
            audioTrackSampleRate == sampleRate &&
            audioTrackChannelCount == safeChannelCount &&
            existing.state != AudioTrack.STATE_UNINITIALIZED
        ) {
            return existing
        }

        releaseTtsAudioTrack()
        val outCh = if (safeChannelCount == 2) AudioFormat.CHANNEL_OUT_STEREO else AudioFormat.CHANNEL_OUT_MONO
        val minBuf = AudioTrack.getMinBufferSize(sampleRate, outCh, AudioFormat.ENCODING_PCM_16BIT).coerceAtLeast(0)
        audioTrack = AudioTrack.Builder()
            .setAudioAttributes(
                android.media.AudioAttributes.Builder()
                    .setUsage(android.media.AudioAttributes.USAGE_MEDIA)
                    .setContentType(android.media.AudioAttributes.CONTENT_TYPE_SPEECH)
                    .build()
            )
            .setAudioFormat(
                AudioFormat.Builder()
                    .setSampleRate(sampleRate)
                    .setChannelMask(outCh)
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                    .build()
            )
            .setBufferSizeInBytes(minBuf.coerceAtLeast(ttsBytesForMs(sampleRate, safeChannelCount, 200)))
            .setTransferMode(AudioTrack.MODE_STREAM)
            .build()
        audioTrackSampleRate = sampleRate
        audioTrackChannelCount = safeChannelCount
        audioTrack?.play()
        return audioTrack
    }

    private fun stopTtsPlayback() {
        val player = synchronized(ttsQueueLock) {
            clearTtsQueueLocked()
            isTtsPlayerRunning = false
            ttsQueueLock.notifyAll()
            ttsPlayerThread.also { ttsPlayerThread = null }
        }
        player?.interrupt()
        releaseTtsAudioTrack()
    }

    private fun resolveTtsSampleRate(r: co.timekettle.translation.model.Result<String>?): Int {
        val raw = r?.extraData?.get("sample_rate") ?: return SAMPLE_RATE
        return when (raw) {
            is Number -> raw.toInt()
            is String -> raw.toIntOrNull()
            else -> null
        }?.takeIf { it > 0 } ?: SAMPLE_RATE
    }

    private fun releaseTtsAudioTrack() {
        try {
            audioTrack?.pause()
            audioTrack?.flush()
            audioTrack?.stop()
            audioTrack?.release()
        } catch (_: Exception) {
        }
        audioTrack = null
        audioTrackSampleRate = 0
        audioTrackChannelCount = 0
    }

    private fun trimTtsQueueLocked(sampleRate: Int, channelCount: Int) {
        val maxBytes = ttsBytesForMs(sampleRate, channelCount, TTS_QUEUE_MAX_MS)
        if (ttsQueuedBytes <= maxBytes) return
        val targetBytes = ttsBytesForMs(sampleRate, channelCount, TTS_QUEUE_TARGET_MS)
        var droppedBytes = 0
        while (ttsQueue.size > 1 && ttsQueuedBytes > targetBytes) {
            val dropped = ttsQueue.removeFirst()
            ttsQueuedBytes -= dropped.data.size
            droppedBytes += dropped.data.size
        }
        if (droppedBytes > 0) {
            Log.w(TAG, "TTS 队列过长，丢弃旧音频约 ${ttsDurationMs(droppedBytes, sampleRate, channelCount)}ms")
        }
    }

    private fun clearTtsQueueLocked() {
        ttsQueue.clear()
        ttsQueuedBytes = 0
        queuedTtsSampleRate = 0
        queuedTtsChannelCount = 0
    }

    private fun ttsBytesForMs(sampleRate: Int, channelCount: Int, ms: Int): Int =
        sampleRate * channelCount * PCM_16BIT_BYTES * ms / 1_000

    private fun ttsDurationMs(bytes: Int, sampleRate: Int, channelCount: Int): Long {
        val bytesPerSecond = sampleRate * channelCount * PCM_16BIT_BYTES
        return if (bytesPerSecond > 0) bytes * 1_000L / bytesPerSecond else 0L
    }

    override fun onCleared() {
        super.onCleared()
        stop()
    }
}
