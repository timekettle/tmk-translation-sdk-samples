package co.timekettle.translation.sample

import co.timekettle.translation.TmkTranslationSDK
import co.timekettle.translation.TmkTranslationChannel
import android.Manifest
import android.app.Application
import android.content.pm.PackageManager
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.os.SystemClock
import android.util.Log
import androidx.core.content.ContextCompat
import androidx.lifecycle.ViewModel
import co.timekettle.translation.Cancelable
import co.timekettle.offlinesdk.vad.VadDetector
import co.timekettle.translation.config.TmkCreateChannelOptions
import co.timekettle.translation.config.TmkTransChannelConfig
import co.timekettle.translation.config.TmkTransGlobalConfig
import co.timekettle.translation.config.TmkTranslationRoomConfig
import co.timekettle.translation.core.AbstractChannelEngine
import co.timekettle.translation.enums.Scenario
import co.timekettle.translation.enums.TmkDialogConversationAudioMode
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
        private const val SAMPLE_RATE = 16000
        private const val CHANNEL_CONFIG = AudioFormat.CHANNEL_IN_MONO
        private const val AUDIO_FORMAT = AudioFormat.ENCODING_PCM_16BIT
        private const val SPEECH_START_TRACE_MIN_INTERVAL_MS = 6_000L
        private const val TTS_QUEUE_MAX_MS = 1_000
        private const val TTS_QUEUE_TARGET_MS = 300
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
    // 下行 TTS 队列式播放器(与离线一对一共用同一实现)。
    private val ttsPlayer = OneToOneTtsQueuePlayer(
        tag = TAG,
        sampleRate = SAMPLE_RATE,
        audioFormat = AUDIO_FORMAT,
        maxQueueMs = TTS_QUEUE_MAX_MS,
        targetQueueMs = TTS_QUEUE_TARGET_MS,
    )
    private var leftVadDetector: VadDetector? = null
    private var rightVadDetector: VadDetector? = null
    @Volatile private var isRecording = false
    private val lifecycleGate = DemoConversationLifecycleGate()
    private val pageSessionId = AtomicInteger(0)
    private val isPreparingChannel = java.util.concurrent.atomic.AtomicBoolean(false)
    /** 因切换通道模式而重建后,是否自动恢复收听(重建前正在收听时置 true)。 */
    @Volatile private var pendingAutoStartAfterRecreate = false
    private var recordingThread: Thread? = null
    private val bubbleAssembler = DemoConversationBubbleAssembler()
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
    private val traceDebounceLock = Any()
    private var lastSpeechStartTraceAtMs: Long = 0

    // 左声道 traceId & 计时
    private var leftTraceId: String? = null
    private var leftVadStartMs: Long = 0
    private var leftFirstAsrMs: Long = 0
    private var leftFirstMtMs: Long = 0
    private var leftFirstTtsMs: Long = 0
    @Volatile private var pendingMetadataLeft: ByteArray? = null

    // 右声道 traceId & 计时
    private var rightTraceId: String? = null
    private var rightVadStartMs: Long = 0
    private var rightFirstAsrMs: Long = 0
    private var rightFirstMtMs: Long = 0
    private var rightFirstTtsMs: Long = 0
    @Volatile private var pendingMetadataRight: ByteArray? = null

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
    private val _currentRoomNo = MutableStateFlow("-")
    val currentRoomNo: StateFlow<String> = _currentRoomNo.asStateFlow()
    private val _captureSampleRate = MutableStateFlow(0)
    val captureSampleRate: StateFlow<Int> = _captureSampleRate.asStateFlow()
    private val _captureChannels = MutableStateFlow(0)
    val captureChannels: StateFlow<Int> = _captureChannels.asStateFlow()
    private val _playbackChannels = MutableStateFlow(0)
    val playbackChannels: StateFlow<Int> = _playbackChannels.asStateFlow()
    private val _sourceLang = MutableStateFlow("zh-CN")
    val sourceLang: StateFlow<String> = _sourceLang.asStateFlow()
    private val _targetLang = MutableStateFlow("en-US")
    val targetLang: StateFlow<String> = _targetLang.asStateFlow()
    private val _leftSpeakerGender = MutableStateFlow(SpeakerGender.MALE)
    val leftSpeakerGender: StateFlow<SpeakerGender> = _leftSpeakerGender.asStateFlow()
    private val _rightSpeakerGender = MutableStateFlow(SpeakerGender.FEMALE)
    val rightSpeakerGender: StateFlow<SpeakerGender> = _rightSpeakerGender.asStateFlow()
    private val _onlineTranslateEngine = MutableStateFlow(TmkOnlineTranslateEngine.ACCURATE)
    val onlineTranslateEngine: StateFlow<TmkOnlineTranslateEngine> = _onlineTranslateEngine.asStateFlow()
    private val _roomScenarioOption = MutableStateFlow(OnlineRoomScenarioOption.defaultOption)
    val roomScenarioOption: StateFlow<OnlineRoomScenarioOption> = _roomScenarioOption.asStateFlow()
    // 通道模式:标准(混合双声道单UID) / 低延迟(左右独立单声道双UID)。
    private val _audioMode = MutableStateFlow(TmkDialogConversationAudioMode.STANDARD)
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

    fun setLanguagesIfNeeded(s: String, t: String) {
        if (hasLockedLanguages) return
        _sourceLang.value = s
        _targetLang.value = t
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
        _channelState.value = snapshot
        _isStarting.value = when (snapshot.state) {
            TmkTranslationChannelState.STARTING,
            TmkTranslationChannelState.RECONNECTING -> true
            else -> false
        }
        refreshChannelReadyFromState()
        applyRuntimeAction(DemoConversationRuntimePolicy.action(snapshot))

        when (snapshot.state) {
            TmkTranslationChannelState.STOPPING -> {
                if (_isStarted.value) stopListening()
            }
            TmkTranslationChannelState.STOPPED -> {
                if (_isStarted.value) stopListening()
            }
            TmkTranslationChannelState.FAILED -> {
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

    private fun buildMetadataBytes(ch: String): ByteArray {
        val sdf = java.text.SimpleDateFormat("HHmmss", java.util.Locale.getDefault())
        val t = sdf.format(java.util.Date())
        return byteArrayOf(ch.toByte(), t.substring(0, 2).toByte(), t.substring(2, 4).toByte(), t.substring(4, 6).toByte())
    }

    private fun metadataToTraceId(m: ByteArray): String =
        m[0].toString() + m.drop(1).joinToString("") { String.format("%02d", it) }

    private fun shouldSendSpeechStartTrace(nowMs: Long): Boolean {
        synchronized(traceDebounceLock) {
            if (lastSpeechStartTraceAtMs != 0L &&
                nowMs - lastSpeechStartTraceAtMs <= SPEECH_START_TRACE_MIN_INTERVAL_MS
            ) {
                return false
            }
            lastSpeechStartTraceAtMs = nowMs
            return true
        }
    }

    private fun resetLeftTrace() {
        leftTraceId = null
        leftVadStartMs = 0
        leftFirstAsrMs = 0
        leftFirstMtMs = 0
        leftFirstTtsMs = 0
        pendingMetadataLeft = null
    }

    private fun resetRightTrace() {
        rightTraceId = null
        rightVadStartMs = 0
        rightFirstAsrMs = 0
        rightFirstMtMs = 0
        rightFirstTtsMs = 0
        pendingMetadataRight = null
    }

    fun initSDK() {
        // 退出竞态守卫:页面已退出(released)时不得再初始化/建房。退出瞬间若有并发的 startTranslation/回调
        // 触发 initSDK,会导致「退出却又建一次房」。合法重建(recreateChannel*)已先置 released=false,不受影响。
        if (lifecycleGate.isReleased()) return
        try {
            if (!_isInitialized.value) {
                TmkTranslationSDK.sdkInit(application, SampleSdkConfig.globalConfig(application))
                TmkTranslationSDK.lingCastTelemetrySetTraceReportingEnabled(true)
                _isInitialized.value = true
                _initErrorMessage.value = null
                addLog("SDK 初始化完成")
            }
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
                _statusText.value = "通道可恢复，正在重新连接..."
                channel?.start()
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
        _statusText.value = "正在收听中..."
        addLog("在线 1v1 已开始采集")
    }

    private fun prepareChannelIfNeeded(sessionId: Int = pageSessionId.get()) {
        if (!DemoConversationPreparationPolicy.canPrepare(lifecycleGate.isReleased(), channel != null)) return
        if (!isPreparingChannel.compareAndSet(false, true)) return
        val startupTiming = StartupTiming()
        _statusText.value = "正在鉴权..."
        addLog("开始鉴权...")
        TmkTranslationSDK.verifyAuth(object : AuthCallback {
            override fun onSuccess() {
                if (!isActiveSession(sessionId)) { isPreparingChannel.set(false); return }
                _statusText.value = "鉴权成功，准备创建房间..."
                addLog("启动翻译耗时 鉴权耗时 authDurationMs=${startupTiming.durationSince(startupTiming.authStartedAtMs)} result=success")
                addLog("鉴权成功")
                doStart(sessionId, startupTiming)
            }
            override fun onError(errorId: Int, e: Exception) {
                isPreparingChannel.set(false)
                if (!isActiveSession(sessionId)) return
                addLog("启动翻译耗时 鉴权耗时 authDurationMs=${startupTiming.durationSince(startupTiming.authStartedAtMs)} totalDurationMs=${startupTiming.totalDurationMs()} result=failure")
                addLog("鉴权失败: [$errorId] ${e.message}")
                _statusText.value = "鉴权失败: ${e.message}"
            }
        })
    }

    private fun doStart(sessionId: Int, startupTiming: StartupTiming) {
        addLog("创建在线 1v1 翻译通道...")
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
                this@Online1v1ViewModel.room = room
                _currentRoomNo.value = room.roomId
                _statusText.value = "房间已创建，正在创建通道..."
                addLog("启动翻译耗时 创建房间耗时 roomDurationMs=${startupTiming.durationSince(startupTiming.roomStartedAtMs)} result=success")
                addLog("创建房间成功: ${room.roomId}")

                val channelConfig = buildOnlineChannelConfig(room)

                addLog("left=${_targetLang.value} right=${_sourceLang.value}")

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
                            refreshChannelReadyFromState()
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
                            addLog("创建 Channel 失败: [$errorId] ${e.message}")
                            _statusText.value = "通道启动失败: ${e.message}"
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
                addLog("创建房间失败: [$errorId] ${e.message}")
                _statusText.value = "房间创建失败: ${e.message}"
            }
        })
    }

    private fun buildRoomConfig(): TmkTranslationRoomConfig {
        val channelLanguages = OnlineOneToOneLanguageMapping.fromDemoSelection(
            sourceLang = _sourceLang.value,
            targetLang = _targetLang.value,
        )
        return TmkTranslationRoomConfig.Builder()
            .setScenario(Scenario.ONE_TO_ONE)
            // SDK 建房参数按 left/right 写入;Demo 业务语义固定为 source=right、target=left。
            .setSourceLang(channelLanguages.leftLang)
            .setTargetLang(channelLanguages.rightLang)
            .setSpeakers(currentSpeakers())
            .setOnlineTranslateEngine(_onlineTranslateEngine.value)
            .setRoomScenario(_roomScenarioOption.value.roomScenario)
            .setTranslateMode(TmkTranslateDeliveryMode.PARTIAL)
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
        val channelLanguages = OnlineOneToOneLanguageMapping.fromDemoSelection(
            sourceLang = _sourceLang.value,
            targetLang = _targetLang.value,
        )
        val builder = TmkTransChannelConfig.Builder()
            .setMode(TranslationMode.ONLINE)
            .setScenario(Scenario.ONE_TO_ONE)
            .setTransModeType(TransModeType.ONE_TO_ONE)
            // SDK 建房参数按 left/right 写入；Demo 业务语义固定为 source=right、target=left。
            .setSourceLang(channelLanguages.leftLang)
            .setTargetLang(channelLanguages.rightLang)
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

    fun updateRoomLocale(sourceLang: String, targetLang: String) {
        val sessionId = pageSessionId.get()
        val currentRoom = room
        if (currentRoom == null || channel == null || !isSdkChannelReady()) {
            _sourceLang.value = sourceLang
            _targetLang.value = targetLang
            addLog("语言已设置为 $sourceLang -> $targetLang，将在创建房间时生效")
            _statusText.value = "语言已切换，将在创建房间时生效"
            return
        }
        if (_isLocaleUpdating.value) return
        _isLocaleUpdating.value = true
        _statusText.value = "正在更新一对一房间语言..."
        currentRoom.updateRoomLocale(
            // 后端一对一房间约定：source_locales 对应左声道，target_locale 对应右声道。
            // Demo 对齐 iOS：左声道=目标语言侧，右声道=源语言/麦克风侧。
            sourceLocales = listOf(targetLang),
            targetLocales = listOf(sourceLang),
            callback = object : ActionCallback {
                override fun onSuccess(result: Result<Unit>) {
                    if (!isActiveSession(sessionId)) return
                    _sourceLang.value = sourceLang
                    _targetLang.value = targetLang
                    _isLocaleUpdating.value = false
                    _playbackChannels.value = 0
                    addLog("语言切换成功: left=$targetLang right=$sourceLang")
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
                    addLog("翻译引擎切换成功: ${engine.name}(${engine.value})")
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
            "left" -> _targetLang.value to _sourceLang.value
            "right" -> _sourceLang.value to _targetLang.value
            else -> _sourceLang.value to _targetLang.value
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

            val now = System.currentTimeMillis()
            if (ch == "left" && leftTraceId != null && leftFirstAsrMs == 0L) {
                leftFirstAsrMs = now
                addLog("ASR [final]:L $text | traceId=$leftTraceId ASR=${now - leftVadStartMs}ms")
            } else if (ch == "right" && rightTraceId != null && rightFirstAsrMs == 0L) {
                rightFirstAsrMs = now
                addLog("ASR [final]:R $text | traceId=$rightTraceId ASR=${now - rightVadStartMs}ms")
            } else {
                addLog("ASR [ch=$ch final=$isFinal]: $text")
            }
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

            val now = System.currentTimeMillis()
            if (ch == "left" && leftTraceId != null && leftFirstMtMs == 0L) {
                leftFirstMtMs = now
                addLog("MT [final]:L $text | traceId=$leftTraceId MT=${now - leftVadStartMs}ms")
            } else if (ch == "right" && rightTraceId != null && rightFirstMtMs == 0L) {
                rightFirstMtMs = now
                addLog("MT [final]:R $text | traceId=$rightTraceId MT=${now - rightVadStartMs}ms")
            } else {
                addLog("MT [ch=$ch final=$isFinal]: $text")
            }
        }

        override fun onAudioDataReceive(
            fromEngine: AbstractChannelEngine?,
            r: co.timekettle.translation.model.Result<String>?,
            data: ByteArray,
            channelCount: Int
        ) {
            _playbackChannels.value = channelCount
            // 立体声按播放音源拆一路(输出单声道)、非立体声直接播;低延迟单路帧仅播选中音源那一路。返回 null 则不播。
            val audioRoute = OneToOnePlaybackSelector.AudioRoute.from(r?.extraData?.get("audio_route"))
            val output = OneToOnePlaybackSelector.selectPlaybackData(
                data = data,
                channelCount = channelCount,
                playbackMode = _playbackMode.value,
                audioRoute = audioRoute,
            ) ?: return
            // 按选择结果的真实声道数播放(立体声拆分后为单声道)。
            ttsPlayer.play(output.data, output.channelCount)
        }

        override fun onError(code: Int, msg: String) {
            val errorText = "翻译错误 [$code]: $msg"
            addLog(errorText)
            showConversationErrorPrompt(OnlineConversationErrorPrompts.fromCode(code, msg))
            stopListening()
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
            if (eventName != "tts_metadata_received") return
            val rid = args as? String ?: return
            val now = System.currentTimeMillis()
            if (rid == leftTraceId && leftFirstTtsMs == 0L) {
                leftFirstTtsMs = now
                addLog("TTS metadata L | traceId=$rid 总=${now - leftVadStartMs}ms")
            } else if (rid == rightTraceId && rightFirstTtsMs == 0L) {
                rightFirstTtsMs = now
                addLog("TTS metadata R | traceId=$rid 总=${now - rightVadStartMs}ms")
            }
        }

        override fun onStateChanged(fromEngine: AbstractChannelEngine?, snapshot: TmkTranslationChannelStateSnapshot) {
            addLog("状态变化: ${snapshot.state.rawValue}/${snapshot.reason.rawValue} ${snapshot.message}")
            applySdkChannelSnapshot(snapshot)
        }
    }

    private fun handleRemoteCloseRoom() {
        addLog("服务端已关闭房间，等待用户确认是否重新创建通道")
        stopTranslation("房间已关闭")
        _remoteCloseRoomPromptVisible.value = true
        _conversationErrorPrompt.value = OnlineConversationErrorPrompts.fromCloseRoom()
    }

    fun recreateChannelAfterRemoteClose() {
        _remoteCloseRoomPromptVisible.value = false
        _conversationErrorPrompt.value = null
        stopTranslation("正在重新创建通道...")
        clearConversation()
        _statusText.value = "正在重新创建通道..."
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

    private fun clearConversation() {
        bubbleAssembler.clear()
        blueSessionByChannel.clear()
        blueChunkByChannel.clear()
        _bubbles.value = emptyList()
        resetLeftTrace()
        resetRightTrace()
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

        rightVadDetector = VadDetector(sampleRate = SAMPLE_RATE).apply {
            setCallback(object : VadDetector.Callback {
                override fun onVadStart() {
                    val nowMs = System.currentTimeMillis()
                    resetRightTrace()
                    if (!shouldSendSpeechStartTrace(nowMs)) {
                        addLog("VAD R → 开始说话 traceId skipped by debounce")
                        return
                    }
                    val m = buildMetadataBytes("2")
                    rightTraceId = metadataToTraceId(m)
                    rightVadStartMs = nowMs - (rightVadDetector?.getVadBeginDurationMs() ?: 0)
                    rightFirstAsrMs = 0; rightFirstMtMs = 0; rightFirstTtsMs = 0
                    pendingMetadataRight = m
                    TmkTranslationSDK.lingCastTelemetryStartTrace(rightTraceId)
                    addLog("VAD R → 开始说话 traceId=$rightTraceId")
                }
                override fun onVadEnd() {
                    val tid = rightTraceId ?: return
                    addLog("VAD R → 停止说话 traceId=$tid 持续${System.currentTimeMillis() - rightVadStartMs}ms")
                }
            })
            init()
        }

        recordingThread = Thread({
            val samplesPer20ms = 320
            val bytesPerCh = samplesPer20ms * 2
            val leftBuf = ByteArray(bytesPerCh)
            val rightBuf = ByteArray(bytesPerCh)
            val stereoBuf = ByteArray(bytesPerCh * 2)
            val leftLoopBuffer = DemoLocalAudioLoopBuffer(readDemoPcmAsset("en_simple.pcm"))

            while (isRecording && isActiveSession(sessionId)) {
                // 对齐 iOS Demo：左声道资产 PCM 播完后先推 3 秒静音，再从头循环。
                val startsNewLeftCycle = leftLoopBuffer.fillNextLoopChunk(leftBuf)

                var ro = 0
                while (ro < bytesPerCh && isRecording) {
                    val r = audioRecord?.read(rightBuf, ro, bytesPerCh - ro) ?: -1
                    if (r > 0) ro += r
                }

                // 对齐 iOS Demo：在线一对一只用右声道麦克风触发 traceId。
                rightVadDetector?.pushAudioBytes(rightBuf)

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

                val leftCycleMetadata = if (startsNewLeftCycle) {
                    buildLeftFileCycleMetadata()
                } else {
                    null
                }

                if (_audioMode.value == TmkDialogConversationAudioMode.LOW_LATENCY) {
                    // 双 UID:左右各推单声道,分别绑定各自连接 track(对齐 iOS pushStreamAudioData(_:speakerChannel:))。
                    // metadata 各归各通道:左声道循环起点 metadata 走左,右声道 VAD traceId metadata 走右。
                    channel?.pushStreamAudioData(leftBuf, SpeakerChannel.LEFT, leftCycleMetadata)
                    val rightMeta = pendingMetadataRight
                    pendingMetadataRight = null
                    channel?.pushStreamAudioData(rightBuf, SpeakerChannel.RIGHT, rightMeta)
                } else {
                    // 标准单 UID:交织立体声整块推流,SDK 内部按混合双声道处理。
                    val extra = leftCycleMetadata ?: pendingMetadataRight
                    if (leftCycleMetadata == null && pendingMetadataRight != null) pendingMetadataRight = null
                    channel?.pushStreamAudioData(stereoBuf, 2, extra)
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

    private fun buildLeftFileCycleMetadata(): ByteArray {
        val metadata = buildMetadataBytes("1")
        val traceId = metadataToTraceId(metadata)
        leftTraceId = traceId
        leftVadStartMs = System.currentTimeMillis()
        leftFirstAsrMs = 0
        leftFirstMtMs = 0
        leftFirstTtsMs = 0
        TmkTranslationSDK.lingCastTelemetryStartTrace(traceId)
        addLog("左路PCM新一轮开始 traceId=$traceId")
        return metadata
    }

    /**
     * 切换本机播放音源(左路/右路翻译)。改字段 + 清空播放缓冲(避免残留反声道数据)+ 刷新 UI,不触碰 RTC。
     */
    fun setPlaybackMode(mode: OneToOnePlaybackMode) {
        if (_playbackMode.value == mode) return
        _playbackMode.value = mode
        ttsPlayer.clearQueue()
        addLog("播放音源切换为 ${mode.title}")
    }

    fun stopListening() {
        stopAudioCapture()
        _isStarted.value = false
        _statusText.value = if (channel != null) "收听已停止" else "已停止"
        addLog("在线 1v1 已停止采集")
    }

    private fun stopAudioCapture() {
        isRecording = false
        leftVadDetector?.release(); leftVadDetector = null
        rightVadDetector?.release(); rightVadDetector = null
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
        ttsPlayer.stop()
    }

    fun stopTranslation(finalStatus: String = "已停止收听") {
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
        _statusText.value = finalStatus
        addLog("在线 1v1 翻译已停止")
    }

    override fun onCleared() {
        super.onCleared()
        stopTranslation()
    }
}
