package co.timekettle.translation.sample

import android.Manifest
import android.app.Application
import android.content.pm.PackageManager
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import androidx.core.content.ContextCompat
import androidx.lifecycle.ViewModel
import co.timekettle.translation.Cancelable
import co.timekettle.translation.TmkTranslationChannel
import co.timekettle.translation.TmkTranslationSDK
import co.timekettle.translation.config.TmkCreateChannelOptions
import co.timekettle.translation.config.TmkTransChannelConfig
import co.timekettle.translation.config.TmkTransGlobalConfig
import co.timekettle.translation.config.TmkTranslationRoomConfig
import co.timekettle.translation.core.AbstractChannelEngine
import co.timekettle.translation.enums.Scenario
import co.timekettle.translation.enums.TmkDialogConversationAudioMode
import co.timekettle.translation.enums.TmkOnlineRecognizeEngine
import co.timekettle.translation.enums.TmkOnlineTranslateEngine
import co.timekettle.translation.enums.TmkSensitiveWordRedactionOption
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
import co.timekettle.translation.model.TmkTranslationChannelStateReason
import co.timekettle.translation.model.TmkTranslationChannelStateSnapshot
import co.timekettle.translation.model.TmkTranslationRoom
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.util.concurrent.atomic.AtomicInteger
import javax.inject.Inject

@HiltViewModel
class Online1v1ViewModel @Inject constructor(
    private val application: Application
) : ViewModel() {

    companion object {
        private const val TAG = "Online1v1VM"
        private const val DEFAULT_BUBBLE_RETENTION_LIMIT = 20
        private const val SAMPLE_RATE = OneToOneDemoDefaults.sampleRate
        private const val CHANNEL_CONFIG = AudioFormat.CHANNEL_IN_MONO
        private const val AUDIO_FORMAT = AudioFormat.ENCODING_PCM_16BIT
        private const val SPEECH_START_TRACE_MIN_INTERVAL_MS = 6_000L
    }

    private data class StartupTiming(
        val startedAtMs: Long = SystemClock.elapsedRealtime(),
        val authStartedAtMs: Long = startedAtMs,
        var roomStartedAtMs: Long = 0L,
        var channelStartedAtMs: Long = 0L,
    ) {
        fun durationSince(startedAtMs: Long): Long = SystemClock.elapsedRealtime() - startedAtMs
        fun totalDurationMs(): Long = durationSince(startedAtMs)
    }

    private var channel: TmkTranslationChannel? = null
    private var room: TmkTranslationRoom? = null
    private var roomCancelable: Cancelable? = null
    private var channelCancelable: Cancelable? = null
    private var speakerCancelable: Cancelable? = null
    private var audioRecord: AudioRecord? = null
    private val ttsCoordinator = DemoTtsPlaybackCoordinator(
        tag = TAG,
        scene = DemoTtsScene.ONE_TO_ONE,
        runtime = DemoTtsRuntime.ONLINE,
        sampleRate = SAMPLE_RATE,
        onPlaybackChannelsChanged = { _playbackChannels.value = it },
    )
    @Volatile private var isRecording = false
    private val lifecycleGate = DemoConversationLifecycleGate()
    private val pageSessionId = AtomicInteger(0)
    private val isPreparingChannel = java.util.concurrent.atomic.AtomicBoolean(false)
    /** 因切换通道模式、识别引擎或翻译下发模式而重建后,是否自动恢复收听(重建前正在收听时置 true)。 */
    @Volatile private var pendingAutoStartAfterRecreate = false
    private var recordingThread: Thread? = null
    private val bubbleAssembler = DemoConversationBubbleAssembler(maxRows = DEFAULT_BUBBLE_RETENTION_LIMIT)
    private val _bubbleRetentionLimit = MutableStateFlow(DEFAULT_BUBBLE_RETENTION_LIMIT)
    val bubbleRetentionLimit: StateFlow<Int> = _bubbleRetentionLimit.asStateFlow()
    /**
     * 当前每个 channel 应高亮的 session_id（源文蓝色），由 online_tts_state.is_end 控制。
     * 同一 channel 永远只有一段文本在高亮，用 Map<channel, sessionId> 保证唯一性。
     * is_end=false 时替换该 channel 的高亮，is_end=true 时清除。
     */
    private val blueSessionByChannel = mutableMapOf<String, String>()
    /**
     * 当前每个 channel 应高亮的 chunk_id（译文蓝色），由 online_tts_state.is_end 控制。
     * 同一 channel 永远只有一段文本在高亮，用 Map<channel, chunkId> 保证唯一性。
     */
    private val blueChunkByChannel = mutableMapOf<String, String>()
    private val networkEventPolicy = DemoOnlineNetworkEventPolicy()
    private val networkStatsTracker = DemoOnlineNetworkStatsTracker()
    private val _networkStats = MutableStateFlow(networkStatsTracker.current())
    val networkStats: StateFlow<DemoOnlineNetworkStatsSnapshot> = _networkStats.asStateFlow()
    private val bootstrapTracker = DemoBootstrapPipelineTracker()
    private val _bootstrapStats = MutableStateFlow(bootstrapTracker.current())
    val bootstrapStats: StateFlow<DemoBootstrapSnapshot> = _bootstrapStats.asStateFlow()
    private val wifiSpeedProbe = DemoWifiSpeedProbe()
    private val _wifiSpeed = MutableStateFlow(DemoWifiSpeedSnapshot())
    val wifiSpeed: StateFlow<DemoWifiSpeedSnapshot> = _wifiSpeed.asStateFlow()

    private val idleChannelSnapshot = TmkTranslationChannelStateSnapshot(
        state = TmkTranslationChannelState.IDLE,
        reason = TmkTranslationChannelStateReason.NONE,
        message = "channel idle"
    )
    private val _channelState = MutableStateFlow(idleChannelSnapshot)
    val channelState: StateFlow<TmkTranslationChannelStateSnapshot> = _channelState.asStateFlow()
    private val _isInitialized = MutableStateFlow(false)
    val isInitialized: StateFlow<Boolean> = _isInitialized.asStateFlow()
    private val _initErrorMessage = MutableStateFlow<String?>(null)
    val initErrorMessage: StateFlow<String?> = _initErrorMessage.asStateFlow()
    private val _isStarted = MutableStateFlow(false)
    val isStarted: StateFlow<Boolean> = _isStarted.asStateFlow()
    private val _isChannelReady = MutableStateFlow(false)
    val isChannelReady: StateFlow<Boolean> = _isChannelReady.asStateFlow()
    private val _isLocaleUpdating = MutableStateFlow(false)
    val isLocaleUpdating: StateFlow<Boolean> = _isLocaleUpdating.asStateFlow()
    private val _isTranslateEngineUpdating = MutableStateFlow(false)
    val isTranslateEngineUpdating: StateFlow<Boolean> = _isTranslateEngineUpdating.asStateFlow()
    private val _isScenarioUpdating = MutableStateFlow(false)
    val isScenarioUpdating: StateFlow<Boolean> = _isScenarioUpdating.asStateFlow()
    private val _isStarting = MutableStateFlow(false)
    val isStarting: StateFlow<Boolean> = _isStarting.asStateFlow()
    private val _logMessages = MutableStateFlow<List<String>>(emptyList())
    val logMessages: StateFlow<List<String>> = _logMessages.asStateFlow()
    private val _bubbles = MutableStateFlow<List<DemoConversationBubbleSnapshot>>(emptyList())
    val bubbles: StateFlow<List<DemoConversationBubbleSnapshot>> = _bubbles.asStateFlow()
    private val _statusText = MutableStateFlow("初始化中...")
    val statusText: StateFlow<String> = _statusText.asStateFlow()
    private val _remoteCloseRoomPromptVisible = MutableStateFlow(false)
    val remoteCloseRoomPromptVisible: StateFlow<Boolean> = _remoteCloseRoomPromptVisible.asStateFlow()
    private val _conversationErrorPrompt = MutableStateFlow<OnlineConversationErrorPrompt?>(null)
    val conversationErrorPrompt: StateFlow<OnlineConversationErrorPrompt?> = _conversationErrorPrompt.asStateFlow()
    private val reconnectTimeoutHandler = Handler(Looper.getMainLooper())
    private var reconnectTimeoutTask: Runnable? = null
    private val reconnectTimeoutMonitor = DemoReconnectTimeoutMonitor(
        schedule = { delayMs, task ->
            reconnectTimeoutTask = Runnable(task)
            reconnectTimeoutHandler.postDelayed(reconnectTimeoutTask!!, delayMs)
        },
        cancelScheduled = {
            reconnectTimeoutTask?.let(reconnectTimeoutHandler::removeCallbacks)
            reconnectTimeoutTask = null
        },
    )
    private val _currentRoomNo = MutableStateFlow("-")
    val currentRoomNo: StateFlow<String> = _currentRoomNo.asStateFlow()
    private val _captureSampleRate = MutableStateFlow(0)
    val captureSampleRate: StateFlow<Int> = _captureSampleRate.asStateFlow()
    private val _captureChannels = MutableStateFlow(0)
    val captureChannels: StateFlow<Int> = _captureChannels.asStateFlow()
    private val _playbackChannels = MutableStateFlow(0)
    val playbackChannels: StateFlow<Int> = _playbackChannels.asStateFlow()
    private val _leftLang = MutableStateFlow("en-US")
    val leftLang: StateFlow<String> = _leftLang.asStateFlow()
    private val _rightLang = MutableStateFlow("zh-CN")
    val rightLang: StateFlow<String> = _rightLang.asStateFlow()
    private val _leftSpeakerGender = MutableStateFlow(OneToOneDemoDefaults.online.leftSpeaker)
    val leftSpeakerGender: StateFlow<SpeakerGender> = _leftSpeakerGender.asStateFlow()
    private val _rightSpeakerGender = MutableStateFlow(OneToOneDemoDefaults.online.rightSpeaker)
    val rightSpeakerGender: StateFlow<SpeakerGender> = _rightSpeakerGender.asStateFlow()
    private val _onlineTranslateEngine = MutableStateFlow(OneToOneDemoDefaults.online.translateEngine)
    val onlineTranslateEngine: StateFlow<TmkOnlineTranslateEngine> = _onlineTranslateEngine.asStateFlow()
    private val _onlineRecognizeEngine = MutableStateFlow(OneToOneDemoDefaults.online.recognizeEngine)
    val onlineRecognizeEngine: StateFlow<TmkOnlineRecognizeEngine> = _onlineRecognizeEngine.asStateFlow()
    // 在线房间的翻译下发模式默认保留服务端 default 语义。
    private val _translateMode = MutableStateFlow(OneToOneDemoDefaults.online.translateMode)
    val translateMode: StateFlow<TmkTranslateDeliveryMode> = _translateMode.asStateFlow()
    private val _roomScenarioOption = MutableStateFlow(OnlineRoomScenarioOption.defaultOption)
    val roomScenarioOption: StateFlow<OnlineRoomScenarioOption> = _roomScenarioOption.asStateFlow()
    // 通道模式:标准(混合双声道单UID) / 低延迟(左右独立单声道双UID)。
    private val _audioMode = MutableStateFlow(OneToOneDemoDefaults.online.audioMode)
    val audioMode: StateFlow<TmkDialogConversationAudioMode> = _audioMode.asStateFlow()
    // 本机播放音源(左路/右路翻译),默认左路。立体声按此拆一路;低延迟单路帧仅播选中那一路。
    private val _playbackMode = MutableStateFlow(OneToOnePlaybackMode.LEFT)
    val playbackMode: StateFlow<OneToOnePlaybackMode> = _playbackMode.asStateFlow()
    private var hasLockedLanguages = false

    /**
     * 切换通道模式(标准/低延迟)。
     *
     * 通道模式在房间创建时下发给服务端并决定底层连接结构,无法热切换;因此若当前已创建通道(收听中或已就绪),
     * 切换后会重建翻译引擎(销毁并重新创建房间+通道)使新模式生效。尚未创建通道时仅记录,下次创建时生效。
     */
    fun setAudioMode(mode: TmkDialogConversationAudioMode) {
        if (_audioMode.value == mode) return
        _audioMode.value = mode
        val modeText = if (mode == TmkDialogConversationAudioMode.LOW_LATENCY) "低延迟模式" else "标准模式"
        val hadChannel = channel != null || _isStarted.value || isPreparingChannel.get()
        if (hadChannel) {
            addLog("通道模式切换为 $modeText，正在重建翻译引擎...")
            recreateChannelForModeChange("正在以$modeText 重建翻译引擎...")
        } else {
            addLog("通道模式切换为 $modeText，将在创建房间时生效")
            _statusText.value = "通道模式已切换为 $modeText"
        }
    }

    /** 翻译下发模式在建房时下发，切换后沿用通道模式的释放并重建流程。 */
    fun setTranslateMode(mode: TmkTranslateDeliveryMode) {
        if (_translateMode.value == mode) return
        _translateMode.value = mode
        val modeText = OnlineTranslateModeOption.from(mode).title
        val hadChannel = channel != null || _isStarted.value || isPreparingChannel.get()
        if (hadChannel) {
            addLog("翻译下发模式切换为 $modeText，正在重建翻译引擎...")
            recreateChannelForModeChange("正在以$modeText 重建翻译引擎...")
        } else {
            addLog("翻译下发模式切换为 $modeText，将在创建房间时生效")
            _statusText.value = "翻译下发模式已切换为 $modeText"
        }
    }

    /**
     * 识别引擎在建房时下发，已创建房间或通道后无法热切换；因此沿用通道模式的释放并重建流程。
     */
    fun setOnlineRecognizeEngine(engine: TmkOnlineRecognizeEngine) {
        if (_onlineRecognizeEngine.value == engine) return
        _onlineRecognizeEngine.value = engine
        val engineText = OnlineRecognizeEngineOption.from(engine).title
        val hadChannel = channel != null || _isStarted.value || isPreparingChannel.get()
        if (hadChannel) {
            addLog("识别引擎切换为 $engineText，正在重建翻译引擎...")
            recreateChannelForModeChange("正在以$engineText 识别引擎重建翻译引擎...")
        } else {
            addLog("识别引擎切换为 $engineText，将在创建房间时生效")
            _statusText.value = "识别引擎已切换为 $engineText"
        }
    }

    fun setLanguagesIfNeeded(leftLanguage: String, rightLanguage: String) {
        if (hasLockedLanguages) return
        _leftLang.value = leftLanguage
        _rightLang.value = rightLanguage
        hasLockedLanguages = true
    }

    private fun nextPageSession(): Int = pageSessionId.incrementAndGet()

    private fun isActiveSession(sessionId: Int): Boolean =
        !lifecycleGate.isReleased() && pageSessionId.get() == sessionId

    private fun isSdkChannelReady(): Boolean {
        return when (_channelState.value.state) {
            TmkTranslationChannelState.RUNNING,
            TmkTranslationChannelState.DEGRADED -> true
            else -> false
        }
    }

    private fun refreshChannelReadyFromState() {
        _isChannelReady.value = channel != null && isSdkChannelReady()
    }

    private fun canRetrySdkChannel(): Boolean {
        val snapshot = _channelState.value
        return snapshot.state == TmkTranslationChannelState.FAILED && snapshot.isRecoverable
    }

    private fun applySdkChannelSnapshot(snapshot: TmkTranslationChannelStateSnapshot) {
        val previousState = _channelState.value.state
        _channelState.value = snapshot
        reconnectTimeoutMonitor.onStateChanged(snapshot.state) {
            if (_channelState.value.state == TmkTranslationChannelState.RECONNECTING &&
                _conversationErrorPrompt.value == null &&
                !_remoteCloseRoomPromptVisible.value
            ) {
                _conversationErrorPrompt.value = OnlineConversationErrorPrompts.fromReconnectTimeout()
            }
        }
        if (snapshot.state != TmkTranslationChannelState.RECONNECTING &&
            _conversationErrorPrompt.value?.id == "reconnect_timeout"
        ) {
            _conversationErrorPrompt.value = null
        }
        _isStarting.value = when (snapshot.state) {
            TmkTranslationChannelState.STARTING,
            TmkTranslationChannelState.RECONNECTING -> true
            else -> false
        }
        refreshChannelReadyFromState()
        applyRuntimeAction(
            DemoConversationRuntimePolicy.action(
                snapshot = snapshot,
                previousState = previousState,
            )
        )

        when (snapshot.state) {
            TmkTranslationChannelState.RUNNING,
            TmkTranslationChannelState.DEGRADED ->
                publishBootstrap(bootstrapTracker.completeChannelReady())
            TmkTranslationChannelState.STOPPING -> {
                // 避免浮窗在 STOPPING/STOPPED/FAILED 后仍展示上一轮“网络良好”的旧 QoS 数据。
                resetNetworkStats()
                if (_isStarted.value) stopListening()
            }
            TmkTranslationChannelState.STOPPED -> {
                // 避免浮窗在 STOPPING/STOPPED/FAILED 后仍展示上一轮“网络良好”的旧 QoS 数据。
                resetNetworkStats()
                if (_isStarted.value) stopListening()
            }
            TmkTranslationChannelState.FAILED -> {
                // 避免浮窗在 STOPPING/STOPPED/FAILED 后仍展示上一轮“网络良好”的旧 QoS 数据。
                resetNetworkStats()
                if (_bootstrapStats.value.isRunning) {
                    publishBootstrap(bootstrapTracker.fail(DemoBootstrapStage.CHANNEL_READY))
                }
                if (_isStarted.value) stopListening()
                showConversationErrorPrompt(OnlineConversationErrorPrompts.fromSnapshot(snapshot))
            }
            else -> Unit
        }
    }

    private fun applyRuntimeAction(action: DemoConversationRuntimeAction) {
        when (action) {
            DemoConversationRuntimeAction.None,
            DemoConversationRuntimeAction.Ignore -> Unit
            is DemoConversationRuntimeAction.Status -> {
                if (action.text == "通道未启动") return
                if (action.text == "通道已停止" && _remoteCloseRoomPromptVisible.value) return
                if (_isStarted.value && action.text == "在线通道已就绪，点击“开始收听”开始采集") return
                _statusText.value = action.text
            }
            is DemoConversationRuntimeAction.WeakNetwork -> _statusText.value = action.text
            is DemoConversationRuntimeAction.Reconnecting -> _statusText.value = action.text
        }
    }

    private fun showConversationErrorPrompt(prompt: OnlineConversationErrorPrompt?) {
        if (prompt == null || _conversationErrorPrompt.value?.id == prompt.id) return
        if (prompt.id != "reconnect_timeout") {
            reconnectTimeoutMonitor.cancel()
            _conversationErrorPrompt.value = null
        }
        _conversationErrorPrompt.value = prompt
    }

    private fun addLog(msg: String) {
        Log.d(TAG, msg)
        _logMessages.value = listOf(msg) + _logMessages.value.take(99)
    }

    private fun publishBubbles() {
        val blueSessions = blueSessionByChannel.values.toSet()
        val blueChunks = blueChunkByChannel.values.toSet()
        _bubbles.value = bubbleAssembler.snapshotWithSegments().map { snapshot ->
            DemoConversationHighlighter.applyHighlight(snapshot, blueSessions, blueChunks)
        }
    }

    fun setBubbleRetentionLimit(limit: Int) {
        val bounded = limit.coerceIn(DemoConversationBubbleAssembler.MIN_MAX_ROWS, DemoConversationBubbleAssembler.MAX_MAX_ROWS)
        bubbleAssembler.setMaxRows(bounded)
        _bubbleRetentionLimit.value = bounded
        publishBubbles()
    }

    /**
     * 收到 online_tts_state：按 channel 维度唯一高亮（同一 channel 永远只有一段文本高亮）。
     * - is_end=false：替换该 channel 的高亮 session_id / chunk_id（清掉旧的，写入新的）。
     * - is_end=true：清除该 channel 的高亮。
     * 源文按 session_id 命中、译文按 chunk_id 命中，随后重渲染所有气泡。
     */
    private fun applyTtsHighlight(args: Any?) {
        val result = args as? Result<*> ?: return
        val isEnd = (result.extraData?.get("is_end") as? Boolean) ?: result.isLast
        val channel = result.extraData?.get("channel")?.toString()?.takeIf { it.isNotBlank() } ?: "left"
        val sessionId = result.sessionId.takeIf { it.isNotBlank() }
        val chunkId = result.extraData?.get("chunk_id")?.toString()?.takeIf { it.isNotBlank() }
        if (isEnd) {
            blueSessionByChannel.remove(channel)
            blueChunkByChannel.remove(channel)
        } else {
            // 同一 channel 唯一高亮：替换而非追加，旧的自动被覆盖。
            sessionId?.let { blueSessionByChannel[channel] = it }
                ?: blueSessionByChannel.remove(channel)
            chunkId?.let { blueChunkByChannel[channel] = it }
                ?: blueChunkByChannel.remove(channel)
        }
        publishBubbles()
    }

    fun initSDK() {
        // 退出竞态守卫:页面已退出(released)时不得再初始化/建房。退出瞬间若有并发的 startTranslation/回调
        // 触发 initSDK,会导致「退出却又建一次房」。合法重建(recreateChannel*)已先置 released=false,不受影响。
        if (lifecycleGate.isReleased()) return
        try {
            if (!_isInitialized.value) {
                TmkTranslationSDK.sdkInit(application, SampleSdkConfig.globalConfig(application))
                _isInitialized.value = true
                _initErrorMessage.value = null
                addLog("SDK 初始化完成")
            }
            startWifiSpeedProbe()
            prepareChannelIfNeeded(pageSessionId.get())
        } catch (e: Exception) {
            addLog("SDK 初始化异常: ${e.message}")
            _statusText.value = "SDK 初始化失败"
            _initErrorMessage.value = SampleSdkConfig.buildInitErrorMessage(e)
            Log.e(TAG, "initSDK failed", e)
        }
    }

    fun dismissInitError() {
        _initErrorMessage.value = null
    }

    fun startTranslation() {
        // 退出竞态守卫:退出瞬间 stopTranslation 已置 channel=null,此时若并发触发 startTranslation,
        // 会因 channel==null 误走「通道未就绪→initSDK 重建」分支,导致退出却又建一次房。released 后直接拒绝。
        if (lifecycleGate.isReleased()) return
        if (!_isInitialized.value || channel == null || !isSdkChannelReady()) {
            if (channel != null && canRetrySdkChannel()) {
                recreateChannelAfterRecoverableFailure()
                return
            }
            addLog("在线通道未就绪，尝试重新准备")
            _statusText.value = "在线通道未就绪，正在重新准备..."
            initSDK()
            return
        }
        if (_isStarted.value) return
        if (!startDualChannelStreaming()) return
        _isStarted.value = true
        ttsCoordinator.setActive(true)
        _statusText.value = "正在收听中..."
        addLog("在线 1v1 已开始采集")
    }

    private fun prepareChannelIfNeeded(sessionId: Int = pageSessionId.get()) {
        if (!DemoConversationPreparationPolicy.canPrepare(lifecycleGate.isReleased(), channel != null)) return
        if (!isPreparingChannel.compareAndSet(false, true)) return
        val startupTiming = StartupTiming()
        publishBootstrap(bootstrapTracker.begin(DemoBootstrapStage.AUTH))
        _statusText.value = "正在鉴权..."
        addLog("开始鉴权...")
        TmkTranslationSDK.verifyAuth(object : AuthCallback {
            override fun onSuccess() {
                if (!isActiveSession(sessionId)) { isPreparingChannel.set(false); return }
                publishBootstrap(bootstrapTracker.complete(DemoBootstrapStage.AUTH))
                _statusText.value = "鉴权成功，准备创建房间..."
                addLog("启动翻译耗时 鉴权耗时 authDurationMs=${startupTiming.durationSince(startupTiming.authStartedAtMs)} result=success")
                addLog("鉴权成功")
                doStart(sessionId, startupTiming)
            }
            override fun onError(errorId: Int, e: Exception) {
                isPreparingChannel.set(false)
                if (!isActiveSession(sessionId)) return
                addLog("启动翻译耗时 鉴权耗时 authDurationMs=${startupTiming.durationSince(startupTiming.authStartedAtMs)} totalDurationMs=${startupTiming.totalDurationMs()} result=failure")
                publishBootstrap(bootstrapTracker.fail(DemoBootstrapStage.AUTH))
                addLog("鉴权失败: [$errorId] ${e.message}")
                _statusText.value = "鉴权失败: ${e.message}"
                showConversationErrorPrompt(OnlineConversationErrorPrompts.fromException(errorId, e))
            }
        })
    }

    private fun doStart(sessionId: Int, startupTiming: StartupTiming) {
        addLog("创建在线 1v1 翻译通道...")
        publishBootstrap(bootstrapTracker.begin(DemoBootstrapStage.CREATE_ROOM))
        _statusText.value = "正在创建房间..."

        roomCancelable?.cancel()
        startupTiming.roomStartedAtMs = SystemClock.elapsedRealtime()
        roomCancelable = TmkTranslationSDK.createTmkTranslationRoom(buildRoomConfig(), object : CreateRoomCallback {
            override fun onSuccess(room: TmkTranslationRoom) {
                roomCancelable = null
                if (!isActiveSession(sessionId)) {
                    TmkTranslationSDK.releaseChannel()
                    isPreparingChannel.set(false)
                    return
                }
                publishBootstrap(bootstrapTracker.complete(DemoBootstrapStage.CREATE_ROOM))
                this@Online1v1ViewModel.room = room
                _currentRoomNo.value = room.roomId
                _statusText.value = "房间已创建，正在创建通道..."
                addLog("启动翻译耗时 创建房间耗时 roomDurationMs=${startupTiming.durationSince(startupTiming.roomStartedAtMs)} result=success")
                addLog("创建房间成功: ${room.roomId}")

                val channelConfig = buildOnlineChannelConfig(room)

                addLog("left=${_leftLang.value} right=${_rightLang.value}")

                publishBootstrap(bootstrapTracker.begin(DemoBootstrapStage.CREATE_CHANNEL))
                channelCancelable?.cancel()
                startupTiming.channelStartedAtMs = SystemClock.elapsedRealtime()
                channelCancelable = TmkTranslationSDK.createTranslationChannel(
                    application,
                    channelConfig,
                    translationListener,
                    object : CreateChannelCallback {
                        override fun onSuccess(ch: TmkTranslationChannel) {
                            channelCancelable = null
                            if (!isActiveSession(sessionId)) {
                                TmkTranslationSDK.releaseChannel()
                                isPreparingChannel.set(false)
                                return
                            }
                            channel = ch
                            publishBootstrap(bootstrapTracker.beginChannelReady())
                            refreshChannelReadyFromState()
                            if (isSdkChannelReady()) {
                                publishBootstrap(bootstrapTracker.completeChannelReady())
                            }
                            addLog("创建在线 1v1 Channel 成功")
                            isPreparingChannel.set(false)
                            addLog("启动翻译耗时 加入通道耗时 channelDurationMs=${startupTiming.durationSince(startupTiming.channelStartedAtMs)} totalDurationMs=${startupTiming.totalDurationMs()} result=success")
                            addLog("在线 1v1 Channel 已就绪")
                            // 因切换通道模式重建的场景:若切换前正在收听,重建就绪后自动恢复收听。
                            if (pendingAutoStartAfterRecreate) {
                                pendingAutoStartAfterRecreate = false
                                startTranslation()
                            }
                        }

                        override fun onError(errorId: Int, e: Exception) {
                            channelCancelable = null
                            isPreparingChannel.set(false)
                            if (!isActiveSession(sessionId)) return
                            addLog("启动翻译耗时 加入通道耗时 channelDurationMs=${startupTiming.durationSince(startupTiming.channelStartedAtMs)} totalDurationMs=${startupTiming.totalDurationMs()} result=failure")
                            publishBootstrap(bootstrapTracker.fail(DemoBootstrapStage.CREATE_CHANNEL))
                            addLog("创建 Channel 失败: [$errorId] ${e.message}")
                            _statusText.value = "通道启动失败: ${e.message}"
                            showConversationErrorPrompt(OnlineConversationErrorPrompts.fromException(errorId, e))
                        }
                    },
                    TmkCreateChannelOptions.defaultConfig()
                )
            }

            override fun onError(errorId: Int, e: Exception) {
                roomCancelable = null
                isPreparingChannel.set(false)
                if (!isActiveSession(sessionId)) return
                addLog("启动翻译耗时 创建房间耗时 roomDurationMs=${startupTiming.durationSince(startupTiming.roomStartedAtMs)} totalDurationMs=${startupTiming.totalDurationMs()} result=failure")
                publishBootstrap(bootstrapTracker.fail(DemoBootstrapStage.CREATE_ROOM))
                addLog("创建房间失败: [$errorId] ${e.message}")
                _statusText.value = "房间创建失败: ${e.message}"
                showConversationErrorPrompt(OnlineConversationErrorPrompts.fromException(errorId, e))
            }
        })
    }

    private fun buildRoomConfig(): TmkTranslationRoomConfig {
        val channelLanguages = OnlineOneToOneLanguageMapping.fromLeftRight(
            leftLang = _leftLang.value,
            rightLang = _rightLang.value,
        )
        return TmkTranslationRoomConfig.Builder()
            .setScenario(Scenario.ONE_TO_ONE)
            // 在线一对一统一语义:source=右路/对方、target=左路/自己。
            .setSourceLang(channelLanguages.rightLang)
            .setTargetLang(channelLanguages.leftLang)
            .setSpeakers(currentSpeakers())
            .setOnlineTranslateEngine(_onlineTranslateEngine.value)
            .setOnlineRecognizeEngine(_onlineRecognizeEngine.value)
            .setRoomScenario(_roomScenarioOption.value.roomScenario)
            .setTranslateMode(_translateMode.value)
            .setDialogConversationAudioMode(_audioMode.value)
            .setEnableSensitiveWordRedaction(
                if (DemoSettingsStore.loadSensitiveWordRedactionEnabled(application)) {
                    TmkSensitiveWordRedactionOption.ENABLED
                } else {
                    TmkSensitiveWordRedactionOption.DISABLED
                }
            )
            .build()
    }

    private fun buildOnlineChannelConfig(room: TmkTranslationRoom?): TmkTransChannelConfig {
        val channelLanguages = OnlineOneToOneLanguageMapping.fromLeftRight(
            leftLang = _leftLang.value,
            rightLang = _rightLang.value,
        )
        val builder = TmkTransChannelConfig.Builder()
            .setMode(TranslationMode.ONLINE)
            .setScenario(Scenario.ONE_TO_ONE)
            .setTransModeType(TransModeType.ONE_TO_ONE)
            // 在线一对一统一语义:source=右路/对方、target=左路/自己。
            .setSourceLang(channelLanguages.rightLang)
            .setTargetLang(channelLanguages.leftLang)
            .setSpeakers(currentSpeakers())
            .setOnlineTranslateEngine(_onlineTranslateEngine.value)
            .setRoomScenario(_roomScenarioOption.value.roomScenario)
            .setSampleRate(SAMPLE_RATE)
            .setChannelNum(2)
        if (room != null) {
            builder.setRoom(room)
        }
        return builder.build()
    }

    fun updateRoomLocale(leftLang: String, rightLang: String) {
        if (!OneToOneSameLanguagePolicy.isOnlineLanguagePairAllowed(
                rightLang,
                leftLang,
                _roomScenarioOption.value.roomScenario,
            )
        ) {
            _statusText.value = OneToOneSameLanguagePolicy.REQUIRES_RECOGNIZE_MESSAGE
            addLog(OneToOneSameLanguagePolicy.REQUIRES_RECOGNIZE_MESSAGE)
            return
        }
        val sessionId = pageSessionId.get()
        val currentRoom = room
        if (currentRoom == null || channel == null || !isSdkChannelReady()) {
            _leftLang.value = leftLang
            _rightLang.value = rightLang
            addLog("语言已设置为 left=$leftLang right=$rightLang，将在创建房间时生效")
            _statusText.value = "语言已切换，将在创建房间时生效"
            return
        }
        if (_isLocaleUpdating.value) return
        _isLocaleUpdating.value = true
        _statusText.value = "正在更新一对一房间语言..."
        currentRoom.updateRoomLocale(
            // SDK 公共参数仍按 source=右路、target=左路传递。
            sourceLocales = listOf(rightLang),
            targetLocales = listOf(leftLang),
            callback = object : ActionCallback {
                override fun onSuccess(result: Result<Unit>) {
                    if (!isActiveSession(sessionId)) return
                    _leftLang.value = leftLang
                    _rightLang.value = rightLang
                    _isLocaleUpdating.value = false
                    _playbackChannels.value = 0
                    addLog("语言切换成功: left=$leftLang right=$rightLang")
                    _statusText.value = "一对一房间语言已更新，下一句话生效"
                }

                override fun onError(errorId: Int, e: Exception) {
                    if (!isActiveSession(sessionId)) return
                    _isLocaleUpdating.value = false
                    addLog("语言切换失败: [$errorId] ${e.message}")
                    _statusText.value = "语言切换失败: ${e.message}"
                }
            }
        )
    }

    fun updateTranslateEngine(engine: TmkOnlineTranslateEngine) {
        val sessionId = pageSessionId.get()
        val currentRoom = room
        if (currentRoom == null || channel == null || !isSdkChannelReady()) {
            _onlineTranslateEngine.value = engine
            addLog("翻译引擎已设置为 ${engine.name}，将在创建房间时生效")
            _statusText.value = "翻译引擎已切换，将在创建房间时生效"
            return
        }
        if (_isTranslateEngineUpdating.value) return
        _isTranslateEngineUpdating.value = true
        _statusText.value = "正在切换翻译引擎..."
        currentRoom.updateTranslateEngine(
            engine = engine,
            callback = object : ActionCallback {
                override fun onSuccess(result: Result<Unit>) {
                    if (!isActiveSession(sessionId)) return
                    _onlineTranslateEngine.value = engine
                    _isTranslateEngineUpdating.value = false
                    addLog("翻译引擎切换成功: ${engine.name}(${engine})")
                    _statusText.value = "翻译引擎已切换，下一句话生效"
                }

                override fun onError(errorId: Int, e: Exception) {
                    if (!isActiveSession(sessionId)) return
                    _isTranslateEngineUpdating.value = false
                    addLog("翻译引擎切换失败: [$errorId] ${e.message}")
                    _statusText.value = "翻译引擎切换失败: ${e.message}"
                }
            }
        )
    }

    fun updateRoomScenario(option: OnlineRoomScenarioOption) {
        if (!OneToOneSameLanguagePolicy.isOnlineLanguagePairAllowed(
                _rightLang.value,
                _leftLang.value,
                option.roomScenario,
            )
        ) {
            _statusText.value = OneToOneSameLanguagePolicy.REQUIRES_RECOGNIZE_MESSAGE
            addLog(OneToOneSameLanguagePolicy.REQUIRES_RECOGNIZE_MESSAGE)
            return
        }
        val sessionId = pageSessionId.get()
        val currentRoom = room
        if (currentRoom == null) {
            _roomScenarioOption.value = option
            addLog("房间能力已设置为${option.title}(${option.roomScenario.value})，将在创建房间时生效")
            _statusText.value = "房间能力已切换为${option.title}，将在创建房间时生效"
            return
        }
        if (_isScenarioUpdating.value) return
        _isScenarioUpdating.value = true
        _statusText.value = "正在切换房间能力..."
        currentRoom.updateScenario(
            scenario = option.roomScenario,
            callback = object : ActionCallback {
                override fun onSuccess(result: Result<Unit>) {
                    if (!isActiveSession(sessionId)) return
                    _roomScenarioOption.value = option
                    _isScenarioUpdating.value = false
                    addLog("房间能力切换成功: ${option.title}(${option.roomScenario.value})")
                    _statusText.value = "房间能力已切换为${option.title}，下一句话生效"
                }

                override fun onError(errorId: Int, e: Exception) {
                    if (!isActiveSession(sessionId)) return
                    _isScenarioUpdating.value = false
                    addLog("房间能力切换失败: [$errorId] ${e.message}")
                    _statusText.value = "房间能力切换失败: ${e.message}"
                }
            }
        )
    }

    fun updateSpeakers(leftGender: SpeakerGender, rightGender: SpeakerGender) {
        _leftSpeakerGender.value = leftGender
        _rightSpeakerGender.value = rightGender
        val currentChannel = channel
        if (currentChannel == null) {
            addLog("音色已设置为 L=${speakerLabel(leftGender)} R=${speakerLabel(rightGender)}，将在创建在线房间时生效")
            _statusText.value = "音色已保存，将在创建在线房间时生效"
            return
        }
        speakerCancelable?.cancel()
        speakerCancelable = currentChannel.updateSpeaker(
            currentSpeakers(),
            object : ActionCallback {
                override fun onSuccess(result: Result<Unit>) {
                    addLog("音色设置成功: L=${speakerLabel(leftGender)} R=${speakerLabel(rightGender)}")
                    _statusText.value = "在线左右声道音色已切换，下一次合成生效"
                }

                override fun onError(errorId: Int, e: Exception) {
                    addLog("音色设置失败: [$errorId] ${e.message}")
                    _statusText.value = "在线音色切换失败: ${e.message}"
                }
            }
        )
    }

    private fun currentSpeakers(): List<TmkSpeaker> = listOf(
        TmkSpeaker(SpeakerChannel.LEFT, _leftSpeakerGender.value),
        TmkSpeaker(SpeakerChannel.RIGHT, _rightSpeakerGender.value),
    )

    private fun speakerLabel(gender: SpeakerGender): String = when (gender) {
        SpeakerGender.MALE -> "男声"
        SpeakerGender.FEMALE -> "女声"
    }

    private fun normalizeChannel(raw: Any?): String {
        return when (raw?.toString()?.lowercase()) {
            "1", "left" -> "left"
            "2", "right" -> "right"
            else -> ""
        }
    }

    private fun languagePairForChannel(channel: String): Pair<String, String> {
        return when (channel) {
            "left" -> _leftLang.value to _rightLang.value
            "right" -> _rightLang.value to _leftLang.value
            else -> _rightLang.value to _leftLang.value
        }
    }

    /**
     * 翻译回调 — 参考 BaseW4LingCastViewModel 的 onRecognize / onTranslate 模式:
     * 1. 通过 bubbleId 查找或创建气泡行
     * 2. 区分 partial / final 更新
     * 3. final 时记录链路计时 (ASR / MT / TTS)
     */
    private val translationListener = object : TmkTranslationListener {

        override fun onRecognized(
            fromEngine: AbstractChannelEngine?,
            r: co.timekettle.translation.model.Result<String>?,
            isFinal: Boolean
        ) {
            Log.d(TAG, DemoTmkResultLogFormatter.makeLine("Online1V1", "ASR", r, isFinal))
            val text = r?.data ?: ""
            val ch = normalizeChannel(r?.extraData?.get("channel"))
            val (src, dst) = languagePairForChannel(ch)

            DemoConversationEventAdapter.makeRecognizedEvent(r, isFinal, src, dst)?.let { bubbleAssembler.consume(it) }
            publishBubbles()

            if (!isFinal) return

            addLog("ASR [ch=$ch final=$isFinal]: $text")
        }

        override fun onTranslate(
            fromEngine: AbstractChannelEngine?,
            r: co.timekettle.translation.model.Result<String>?,
            isFinal: Boolean
        ) {
            Log.d(TAG, DemoTmkResultLogFormatter.makeLine("Online1V1", "MT", r, isFinal))
            val text = r?.data ?: ""
            val ch = normalizeChannel(r?.extraData?.get("channel"))
            val (src, dst) = languagePairForChannel(ch)

            DemoConversationEventAdapter.makeTranslatedEvent(r, isFinal, src, dst)?.let { bubbleAssembler.consume(it) }
            publishBubbles()

            if (!isFinal) return

            addLog("MT [ch=$ch final=$isFinal]: $text")
        }

        override fun onAudioDataReceive(
            fromEngine: AbstractChannelEngine?,
            r: co.timekettle.translation.model.Result<String>?,
            data: ByteArray,
            channelCount: Int
        ) {
            ttsCoordinator.handleAudioData(r, data, channelCount)
        }

        override fun onError(code: Int, msg: String) {
            val errorText = "翻译错误 [$code]: $msg"
            addLog(errorText)
            showConversationErrorPrompt(OnlineConversationErrorPrompts.fromCode(code, msg))
            if (OnlineConversationErrorPrompts.shouldStopChannel(code)) {
                stopListening()
            }
        }

        override fun onEvent(eventName: String, args: Any?) {
            if (OnlineRoomEventHelper.isCloseRoomNotification(eventName, args)) {
                handleRemoteCloseRoom()
                return
            }
            if (networkEventPolicy.isExpectedServiceUserOffline(eventName, args)) {
                addLog("服务端音频用户离线，等待用户确认是否重新创建通道")
                stopTranslation("通道已不可用")
                _remoteCloseRoomPromptVisible.value = true
                _conversationErrorPrompt.value = OnlineConversationErrorPrompt(
                    id = "service_user_offline",
                    title = "通道已不可用",
                    message = "服务端音频通道已断开，当前对话无法继续使用。请重新创建一个全新的对话。"
                )
                return
            }

        // 先更新宿主侧统计快照：即便后续弱网提示走了 return，也要保证浮窗数据刷新。
        networkStatsTracker.consume(eventName, args)?.let { snapshot ->
            _networkStats.value = snapshot
        }

            networkEventPolicy.statusForEvent(eventName, args)?.let { status ->
                addLog("网络事件提示: $eventName $status")
                applyRuntimeAction(DemoConversationRuntimeAction.WeakNetwork(status))
                return
            }
            if (eventName == "online_bubble_end") {
                val result = args as? co.timekettle.translation.model.Result<*> ?: return
                val bubbleId = result.bubbleId.takeIf { it.isNotBlank() }
                    ?: result.extraData?.get("bubble_id")?.toString()?.takeIf { it.isNotBlank() }
                    ?: return
                val affectedRows = bubbleAssembler.markBubbleEnded(bubbleId)
                Log.d(TAG, DemoTmkResultLogFormatter.makeBubbleEndLine("Online1V1", result, affectedRows.size))
                publishBubbles()
                return
            }
            if (eventName == "online_tts_state") {
                applyTtsHighlight(args)
                return
            }
        }

        override fun onStateChanged(fromEngine: AbstractChannelEngine?, snapshot: TmkTranslationChannelStateSnapshot) {
            addLog("状态变化: ${snapshot.state.rawValue}/${snapshot.reason.rawValue} ${snapshot.message}")
            applySdkChannelSnapshot(snapshot)
        }
    }

    private fun handleRemoteCloseRoom() {
        reconnectTimeoutMonitor.cancel()
        addLog("服务端已关闭房间，等待用户确认是否重新创建通道")
        stopTranslation("房间已关闭")
        _remoteCloseRoomPromptVisible.value = true
        _conversationErrorPrompt.value = OnlineConversationErrorPrompts.fromCloseRoom()
    }

    fun recreateChannelAfterRemoteClose() {
        reconnectTimeoutMonitor.cancel()
        _remoteCloseRoomPromptVisible.value = false
        _conversationErrorPrompt.value = null
        stopTranslation("正在重新创建通道...")
        clearConversation()
        _statusText.value = "正在重新创建通道..."
        lifecycleGate.reopen()
        initSDK()
    }

    /** 可恢复失败后释放旧会话，重新走 SDK 内部的加入通道流程。 */
    private fun recreateChannelAfterRecoverableFailure() {
        val status = "通道可恢复，正在重新加入..."
        stopTranslation(status)
        clearConversation()
        lifecycleGate.reopen()
        initSDK()
    }

    /**
     * 因切换通道模式而重建翻译引擎:销毁当前房间+通道并按新模式重新创建。
     * 若切换前正在收听,重建就绪后自动恢复收听,保证用户无感切换。
     */
    private fun recreateChannelForModeChange(status: String) {
        val wasListening = _isStarted.value
        stopTranslation(status)
        clearConversation()
        _statusText.value = status
        lifecycleGate.reopen()
        pendingAutoStartAfterRecreate = wasListening
        initSDK()
    }

    fun dismissRemoteCloseRoomPrompt() {
        _remoteCloseRoomPromptVisible.value = false
        _conversationErrorPrompt.value = null
    }

    fun recreateChannelAfterReconnectTimeout() {
        reconnectTimeoutMonitor.cancel()
        _conversationErrorPrompt.value = null
        stopTranslation("正在重新创建通道...")
        clearConversation()
        _statusText.value = "正在重新创建通道..."
        lifecycleGate.reopen()
        initSDK()
    }

    fun continueWaitingAfterReconnectTimeout() {
        _conversationErrorPrompt.value = null
        reconnectTimeoutMonitor.continueWaiting {
            if (_channelState.value.state == TmkTranslationChannelState.RECONNECTING &&
                _conversationErrorPrompt.value == null &&
                !_remoteCloseRoomPromptVisible.value
            ) {
                _conversationErrorPrompt.value = OnlineConversationErrorPrompts.fromReconnectTimeout()
            }
        }
    }

    private fun clearConversation() {
        bubbleAssembler.clear()
        blueSessionByChannel.clear()
        blueChunkByChannel.clear()
        _bubbles.value = emptyList()
        resetNetworkStats()
    }

    private fun resetNetworkStats() {
        _networkStats.value = networkStatsTracker.reset()
    }

    private fun publishBootstrap(snapshot: DemoBootstrapSnapshot) {
        _bootstrapStats.value = snapshot
    }

    private fun startWifiSpeedProbe() {
        val businessBaseUrl = SampleSdkConfig.globalConfig(application).resolvedNetworkBaseURL
        wifiSpeedProbe.start(businessBaseUrl = businessBaseUrl) { snapshot ->
            _wifiSpeed.value = snapshot
        }
    }

    private fun cancelWifiSpeedProbe() {
        wifiSpeedProbe.cancel()
        val current = _wifiSpeed.value
        if (current.status == DemoWifiSpeedStatus.RUNNING || current.status == DemoWifiSpeedStatus.IDLE) {
            _wifiSpeed.value = current.copy(status = DemoWifiSpeedStatus.CANCELLED)
        }
    }

    private fun startDualChannelStreaming(): Boolean {
        if (ContextCompat.checkSelfPermission(application, Manifest.permission.RECORD_AUDIO)
            != PackageManager.PERMISSION_GRANTED
        ) {
            addLog("没有录音权限")
            _statusText.value = "麦克风权限未授权"
            return false
        }

        val bufferSize = AudioRecord.getMinBufferSize(SAMPLE_RATE, CHANNEL_CONFIG, AUDIO_FORMAT)
        val sessionId = pageSessionId.get()
        audioRecord = AudioRecord(MediaRecorder.AudioSource.MIC, SAMPLE_RATE, CHANNEL_CONFIG, AUDIO_FORMAT, bufferSize)
        isRecording = true
        audioRecord?.startRecording()

        addLog("双声道推流 (左:资产PCM, 右:麦克风)")
        _captureSampleRate.value = SAMPLE_RATE
        _captureChannels.value = 2

        recordingThread = Thread({
            val samplesPer20ms = 320
            val bytesPerCh = samplesPer20ms * 2
            val leftBuf = ByteArray(bytesPerCh)
            val rightBuf = ByteArray(bytesPerCh)
            val stereoBuf = ByteArray(bytesPerCh * 2)
            val leftLoopBuffer = DemoLocalAudioLoopBuffer(readDemoPcmAsset("en_simple.pcm"))

            while (isRecording && isActiveSession(sessionId)) {
                // 对齐 iOS Demo：左声道资产 PCM 播完后先推 3 秒静音，再从头循环。
                leftLoopBuffer.fillNextLoopChunk(leftBuf)

                var ro = 0
                while (ro < bytesPerCh && isRecording) {
                    val r = audioRecord?.read(rightBuf, ro, bytesPerCh - ro) ?: -1
                    if (r > 0) ro += r
                }

                // 交织成立体声
                var si = 0
                for (i in 0 until samplesPer20ms) {
                    val bi = i * 2
                    stereoBuf[si] = leftBuf[bi]
                    stereoBuf[si + 1] = leftBuf[bi + 1]
                    stereoBuf[si + 2] = rightBuf[bi]
                    stereoBuf[si + 3] = rightBuf[bi + 1]
                    si += 4
                }

                if (_audioMode.value == TmkDialogConversationAudioMode.LOW_LATENCY) {
                    // 双 UID:左右各推单声道,分别绑定各自连接 track(对齐 iOS pushStreamAudioData(_:speakerChannel:))。
                    channel?.pushStreamAudioData(leftBuf, SpeakerChannel.LEFT, null)
                    channel?.pushStreamAudioData(rightBuf, SpeakerChannel.RIGHT, null)
                } else {
                    // 标准单 UID:交织立体声整块推流,SDK 内部按混合双声道处理。
                    channel?.pushStreamAudioData(stereoBuf, 2, null)
                }
            }
        }, "$TAG-Recorder").apply { start() }
        return true
    }

    private fun readDemoPcmAsset(fileName: String): ByteArray? {
        return try {
            application.assets.open(fileName).use { it.readBytes() }
        } catch (e: Exception) {
            addLog("读取资产PCM失败: ${e.message}")
            null
        }
    }

    /**
     * 切换本机播放音源(左路/右路翻译)。改字段 + 停止当前帧/播放线程(避免残留反声道数据)+ 刷新 UI,不触碰 RTC。
     */
    fun setPlaybackMode(mode: OneToOnePlaybackMode) {
        if (_playbackMode.value == mode) return
        _playbackMode.value = mode
        ttsCoordinator.setPlaybackMode(mode)
        addLog("播放音源切换为 ${mode.title}")
    }

    fun stopListening() {
        stopAudioCapture()
        _isStarted.value = false
        resetNetworkStats()
        _statusText.value = if (channel != null) "收听已停止" else "已停止"
        addLog("在线 1v1 已停止采集")
    }

    private fun stopAudioCapture() {
        isRecording = false
        try {
            audioRecord?.stop()
            audioRecord?.release()
        } catch (_: Exception) {}
        audioRecord = null
        recordingThread?.interrupt()
        try { recordingThread?.join(300) } catch (_: InterruptedException) {}
        recordingThread = null
        _captureSampleRate.value = 0
        _captureChannels.value = 0
        _playbackChannels.value = 0
        ttsCoordinator.setActive(false)
        ttsCoordinator.release()
    }

    fun stopTranslation(finalStatus: String = "已停止收听") {
        reconnectTimeoutMonitor.cancel()
        if (!lifecycleGate.tryRelease()) return
        nextPageSession()
        isPreparingChannel.set(false)
        pendingAutoStartAfterRecreate = false
        roomCancelable?.cancel()
        roomCancelable = null
        channelCancelable?.cancel()
        channelCancelable = null
        speakerCancelable?.cancel()
        speakerCancelable = null
        cancelWifiSpeedProbe()
        stopAudioCapture()
        addLog("录音已停止")

        TmkTranslationSDK.releaseChannel()
        channel = null
        room = null
        _currentRoomNo.value = "-"
        _isLocaleUpdating.value = false
        _isTranslateEngineUpdating.value = false
        _isStarted.value = false
        _isStarting.value = false
        _isChannelReady.value = false
        _channelState.value = idleChannelSnapshot
        hasLockedLanguages = false
        resetNetworkStats()
        _statusText.value = finalStatus
        addLog("在线 1v1 翻译已停止")
    }

    override fun onCleared() {
        reconnectTimeoutMonitor.cancel()
        super.onCleared()
        stopTranslation()
    }
}
