package co.timekettle.translation.sample

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
import co.timekettle.translation.TmkTranslationChannel
import co.timekettle.translation.TmkTranslationSDK
import co.timekettle.offlinesdk.vad.VadDetector
import co.timekettle.translation.config.TmkCreateChannelOptions
import co.timekettle.translation.config.TmkTransChannelConfig
import co.timekettle.translation.config.TmkTransGlobalConfig
import co.timekettle.translation.config.TmkTranslationRoomConfig
import co.timekettle.translation.core.AbstractChannelEngine
import co.timekettle.translation.enums.Scenario
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
class OnlineListenViewModel @Inject constructor(
    private val application: Application
) : ViewModel() {

    companion object {
        private const val TAG = "OnlineListenVM"
        private const val SAMPLE_RATE = 16000
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
        scene = DemoTtsScene.LISTEN,
        sampleRate = SAMPLE_RATE,
        onPlaybackChannelsChanged = { _playbackChannels.value = it },
    )
    private var vadDetector: VadDetector? = null
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

    @Volatile private var isRecording = false
    private val lifecycleGate = DemoConversationLifecycleGate()
    private val pageSessionId = AtomicInteger(0)
    private val isPreparingChannel = java.util.concurrent.atomic.AtomicBoolean(false)
    /** 因切换识别引擎或翻译下发模式而重建后,是否自动恢复收听(重建前正在收听时置 true)。 */
    @Volatile private var pendingAutoStartAfterRecreate = false
    private var recordingThread: Thread? = null

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
    private val _speakerGender = MutableStateFlow(SpeakerGender.FEMALE)
    val speakerGender: StateFlow<SpeakerGender> = _speakerGender.asStateFlow()
    private val _onlineTranslateEngine = MutableStateFlow(TmkOnlineTranslateEngine.ACCURATE)
    val onlineTranslateEngine: StateFlow<TmkOnlineTranslateEngine> = _onlineTranslateEngine.asStateFlow()
    private val _onlineRecognizeEngine = MutableStateFlow(TmkOnlineRecognizeEngine.DEFAULT)
    val onlineRecognizeEngine: StateFlow<TmkOnlineRecognizeEngine> = _onlineRecognizeEngine.asStateFlow()
    private val _translateMode = MutableStateFlow(TmkTranslateDeliveryMode.DEFAULT)
    val translateMode: StateFlow<TmkTranslateDeliveryMode> = _translateMode.asStateFlow()
    private val _roomScenarioOption = MutableStateFlow(OnlineRoomScenarioOption.defaultOption)
    val roomScenarioOption: StateFlow<OnlineRoomScenarioOption> = _roomScenarioOption.asStateFlow()
    private var hasLockedLanguages = false
    /** 待对齐语言:通道未就绪/下发中时记账,就绪后与服务端建房语言比对补发。仅主线程访问。 */
    private var pendingSourceLang: String? = null
    private var pendingTargetLang: String? = null

    private fun log(msg: String) = Log.d(TAG, msg)

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

    fun setLanguagesIfNeeded(sourceLang: String, targetLang: String) {
        if (hasLockedLanguages) return
        _sourceLang.value = sourceLang; _targetLang.value = targetLang; hasLockedLanguages = true
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
            log("识别引擎切换为 $engineText，正在重建翻译引擎...")
            recreateChannelForRoomConfigChange("正在以$engineText 识别引擎重建翻译引擎...")
        } else {
            log("识别引擎切换为 $engineText，将在创建房间时生效")
            _statusText.value = "识别引擎已切换为 $engineText"
        }
    }

    /** 翻译下发模式在建房时下发，切换后沿用通道模式的释放并重建流程。 */
    fun setTranslateMode(mode: TmkTranslateDeliveryMode) {
        if (_translateMode.value == mode) return
        _translateMode.value = mode
        val modeText = OnlineTranslateModeOption.from(mode).title
        val hadChannel = channel != null || _isStarted.value || isPreparingChannel.get()
        if (hadChannel) {
            log("翻译下发模式切换为 $modeText，正在重建翻译引擎...")
            recreateChannelForRoomConfigChange("正在以$modeText 重建翻译引擎...")
        } else {
            log("翻译下发模式切换为 $modeText，将在创建房间时生效")
            _statusText.value = "翻译下发模式已切换为 $modeText"
        }
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
        // 通道进入可用态:补发建房窗口内积压的语言变更(见 bug 7024923916)。
        when (snapshot.state) {
            TmkTranslationChannelState.RUNNING,
            TmkTranslationChannelState.DEGRADED ->
                reconcilePendingLocaleIfNeeded(pageSessionId.get())
            else -> Unit
        }

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

    fun initSDK() {
        // 退出竞态守卫:页面已退出(released)时不得再初始化/建房,避免退出瞬间并发触发导致重复建房。
        // 合法重建(recreateChannel*)已先置 released=false,不受影响。
        if (lifecycleGate.isReleased()) return
        try {
            if (!_isInitialized.value) {
                TmkTranslationSDK.sdkInit(application, SampleSdkConfig.globalConfig(application))
                _isInitialized.value = true
                _initErrorMessage.value = null
                log("SDK 初始化完成")
            }
            prepareChannelIfNeeded(pageSessionId.get())
        } catch (e: Exception) {
            log("SDK 初始化异常: ${e.message}")
            _statusText.value = "SDK 初始化失败"
            _initErrorMessage.value = SampleSdkConfig.buildInitErrorMessage(e)
            Log.e(TAG, "initSDK failed", e)
        }
    }

    fun dismissInitError() {
        _initErrorMessage.value = null
    }

    fun startTranslation() {
        // 退出竞态守卫:退出后 channel 已置空,并发的 startTranslation 会误走 initSDK 重建分支导致重复建房。
        if (lifecycleGate.isReleased()) return
        if (!_isInitialized.value || channel == null || !isSdkChannelReady()) {
            if (channel != null && canRetrySdkChannel()) {
                recreateChannelAfterRecoverableFailure()
                return
            }
            _statusText.value = "在线通道未就绪，正在重新准备..."
            log("在线通道未就绪，尝试重新准备")
            initSDK()
            return
        }
        if (_isStarted.value) return
        if (!startRecording()) return
        _isStarted.value = true
        ttsCoordinator.setActive(true)
        _statusText.value = "正在收听中..."
        log("在线收听已开始采集")
    }

    private fun prepareChannelIfNeeded(sessionId: Int = pageSessionId.get()) {
        if (!DemoConversationPreparationPolicy.canPrepare(lifecycleGate.isReleased(), channel != null)) return
        if (!isPreparingChannel.compareAndSet(false, true)) return
        val startupTiming = StartupTiming()
        _statusText.value = "正在鉴权..."
        log("开始鉴权...")
        TmkTranslationSDK.verifyAuth(object : AuthCallback {
            override fun onSuccess() {
                if (!isActiveSession(sessionId)) { isPreparingChannel.set(false); return }
                _statusText.value = "鉴权成功，准备创建房间..."
                log("启动翻译耗时 鉴权耗时 authDurationMs=${startupTiming.durationSince(startupTiming.authStartedAtMs)} result=success")
                log("鉴权成功"); doStart(sessionId, startupTiming)
            }
            override fun onError(errorId: Int, e: Exception) {
                isPreparingChannel.set(false)
                if (!isActiveSession(sessionId)) return
                log("启动翻译耗时 鉴权耗时 authDurationMs=${startupTiming.durationSince(startupTiming.authStartedAtMs)} totalDurationMs=${startupTiming.totalDurationMs()} result=failure")
                log("鉴权失败: [$errorId] ${e.message}")
                _statusText.value = "鉴权失败: ${e.message}"
                showConversationErrorPrompt(OnlineConversationErrorPrompts.fromException(errorId, e))
            }
        })
    }

    private fun doStart(sessionId: Int, startupTiming: StartupTiming) {
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
                this@OnlineListenViewModel.room = room
                _currentRoomNo.value = room.roomId
                _statusText.value = "房间已创建，正在创建通道..."
                log("启动翻译耗时 创建房间耗时 roomDurationMs=${startupTiming.durationSince(startupTiming.roomStartedAtMs)} result=success")
                log("创建房间成功: ${room.roomId}")
                val cfg = buildOnlineChannelConfig(room)
                channelCancelable?.cancel()
                startupTiming.channelStartedAtMs = SystemClock.elapsedRealtime()
                channelCancelable = TmkTranslationSDK.createTranslationChannel(application, cfg, listener, object : CreateChannelCallback {
                    override fun onSuccess(ch: TmkTranslationChannel) {
                        channelCancelable = null
                        if (!isActiveSession(sessionId)) {
                            TmkTranslationSDK.releaseChannel()
                            isPreparingChannel.set(false)
                            return
                        }
                        channel = ch
                        refreshChannelReadyFromState()
                        isPreparingChannel.set(false)
                        log("启动翻译耗时 加入通道耗时 channelDurationMs=${startupTiming.durationSince(startupTiming.channelStartedAtMs)} totalDurationMs=${startupTiming.totalDurationMs()} result=success")
                        log("Channel 已就绪")
                        // 通道就绪:若建房窗口内改过语言,补发对齐服务端(见 bug 7024923916)。
                        reconcilePendingLocaleIfNeeded(sessionId)
                        if (pendingAutoStartAfterRecreate) {
                            pendingAutoStartAfterRecreate = false
                            startTranslation()
                        }
                    }
                    override fun onError(errorId: Int, e: Exception) {
                        channelCancelable = null
                        isPreparingChannel.set(false)
                        if (!isActiveSession(sessionId)) return
                        log("启动翻译耗时 加入通道耗时 channelDurationMs=${startupTiming.durationSince(startupTiming.channelStartedAtMs)} totalDurationMs=${startupTiming.totalDurationMs()} result=failure")
                        log("创建 Channel 失败: [$errorId] ${e.message}")
                        _statusText.value = "通道启动失败: ${e.message}"
                        showConversationErrorPrompt(OnlineConversationErrorPrompts.fromException(errorId, e))
                    }
                }, TmkCreateChannelOptions.defaultConfig())
            }
            override fun onError(errorId: Int, e: Exception) {
                roomCancelable = null
                isPreparingChannel.set(false)
                if (!isActiveSession(sessionId)) return
                log("启动翻译耗时 创建房间耗时 roomDurationMs=${startupTiming.durationSince(startupTiming.roomStartedAtMs)} totalDurationMs=${startupTiming.totalDurationMs()} result=failure")
                log("创建房间失败: [$errorId] ${e.message}")
                _statusText.value = "房间创建失败: ${e.message}"
                showConversationErrorPrompt(OnlineConversationErrorPrompts.fromException(errorId, e))
            }
        })
    }

    private fun buildRoomConfig(): TmkTranslationRoomConfig {
        return TmkTranslationRoomConfig.Builder()
            .setScenario(Scenario.LISTEN)
            .setSourceLang(_sourceLang.value)
            .setTargetLang(_targetLang.value)
            .setSpeakers(listOf(TmkSpeaker(SpeakerChannel.LEFT, _speakerGender.value)))
            .setOnlineTranslateEngine(_onlineTranslateEngine.value)
            .setOnlineRecognizeEngine(_onlineRecognizeEngine.value)
            .setTranslateMode(_translateMode.value)
            .setRoomScenario(_roomScenarioOption.value.roomScenario)
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
        val builder = TmkTransChannelConfig.Builder()
            .setMode(TranslationMode.ONLINE)
            .setScenario(Scenario.LISTEN)
            .setTransModeType(TransModeType.LISTEN)
            .setSourceLang(_sourceLang.value)
            .setTargetLang(_targetLang.value)
            .setSpeakers(listOf(TmkSpeaker(SpeakerChannel.LEFT, _speakerGender.value)))
            .setOnlineTranslateEngine(_onlineTranslateEngine.value)
            .setRoomScenario(_roomScenarioOption.value.roomScenario)
            .setSampleRate(SAMPLE_RATE)
            .setChannelNum(1)
        if (room != null) {
            builder.setRoom(room)
        }
        return builder.build()
    }

    fun updateRoomLocale(sourceLang: String, targetLang: String) {
        val sessionId = pageSessionId.get()
        val currentRoom = room
        if (currentRoom == null || channel == null || !isSdkChannelReady()) {
            // 通道未就绪:记账并更新 UI,待就绪后由 reconcilePendingLocaleIfNeeded 同步到服务端,不丢失变更。
            pendingSourceLang = sourceLang
            pendingTargetLang = targetLang
            _sourceLang.value = sourceLang
            _targetLang.value = targetLang
            _statusText.value = "语言已切换，将在通道就绪后同步到房间"
            log("语言已设置为 $sourceLang -> $targetLang，将在通道就绪后同步到房间")
            return
        }
        if (_isLocaleUpdating.value) {
            // 正在下发:并入 pending,完成后由 reconcile 收敛,避免并发下发。
            pendingSourceLang = sourceLang
            pendingTargetLang = targetLang
            return
        }
        submitRoomLocale(currentRoom, sessionId, sourceLang, targetLang)
    }

    /** 向服务端下发房间语言;成功后回写 UI 并尝试收敛 pending。 */
    private fun submitRoomLocale(
        currentRoom: TmkTranslationRoom,
        sessionId: Int,
        sourceLang: String,
        targetLang: String,
    ) {
        _isLocaleUpdating.value = true
        _statusText.value = "正在更新房间语言..."
        currentRoom.updateRoomLocale(
            sourceLocales = listOf(sourceLang),
            targetLocales = listOf(targetLang),
            callback = object : ActionCallback {
                override fun onSuccess(result: Result<Unit>) {
                    if (!isActiveSession(sessionId)) return
                    _sourceLang.value = sourceLang
                    _targetLang.value = targetLang
                    _isLocaleUpdating.value = false
                    _playbackChannels.value = 0
                    _statusText.value = "房间语言已更新，下一句话生效"
                    log("语言切换成功: $sourceLang -> $targetLang")
                    // 下发期间若又改过语言,收敛到最新期望。
                    reconcilePendingLocaleIfNeeded(sessionId)
                }

                override fun onError(errorId: Int, e: Exception) {
                    if (!isActiveSession(sessionId)) return
                    _isLocaleUpdating.value = false
                    _statusText.value = "语言切换失败: ${e.message}"
                    log("语言切换失败: [$errorId] ${e.message}")
                    // 失败保留 pending,留待下次就绪/手动重试,不自动重试以免雪崩。
                }
            }
        )
    }

    /**
     * 通道就绪后补发「积压的语言切换」。
     *
     * 仅处理 pending(通道未就绪 / 上一笔下发进行中时累积的切换),把它下发一次后清空。
     * 不读取建房 translationList 做比较——该值建房后不可变,比较会导致正常切换后无限重发。
     * 「建房语言 != 期望」的兜底由 SDK join 侧负责(只在 join 时触发一次,不会循环)。
     * 仅主线程调用。
     */
    private fun reconcilePendingLocaleIfNeeded(sessionId: Int) {
        if (!isActiveSession(sessionId)) return
        val currentRoom = room ?: return
        if (channel == null || !isSdkChannelReady() || _isLocaleUpdating.value) return

        val target = pendingTargetLang ?: return // 无积压则不动作,避免正常切换后重复下发
        val source = pendingSourceLang ?: _sourceLang.value
        pendingSourceLang = null
        pendingTargetLang = null
        log("补发积压的语言切换: $source -> $target")
        submitRoomLocale(currentRoom, sessionId, source, target)
    }

    fun updateTranslateEngine(engine: TmkOnlineTranslateEngine) {
        val sessionId = pageSessionId.get()
        val currentRoom = room
        if (currentRoom == null || channel == null || !isSdkChannelReady()) {
            _onlineTranslateEngine.value = engine
            _statusText.value = "翻译引擎已切换，将在创建房间时生效"
            log("翻译引擎已设置为 ${engine.name}，将在创建房间时生效")
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
                    _statusText.value = "翻译引擎已切换，下一句话生效"
                    log("翻译引擎切换成功: ${engine.name}(${engine})")
                }

                override fun onError(errorId: Int, e: Exception) {
                    if (!isActiveSession(sessionId)) return
                    _isTranslateEngineUpdating.value = false
                    _statusText.value = "翻译引擎切换失败: ${e.message}"
                    log("翻译引擎切换失败: [$errorId] ${e.message}")
                }
            }
        )
    }

    fun updateRoomScenario(option: OnlineRoomScenarioOption) {
        val sessionId = pageSessionId.get()
        val currentRoom = room
        if (currentRoom == null) {
            _roomScenarioOption.value = option
            _statusText.value = "房间能力已切换为${option.title}，将在创建房间时生效"
            log("房间能力已设置为${option.title}(${option.roomScenario.value})，将在创建房间时生效")
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
                    _statusText.value = "房间能力已切换为${option.title}，下一句话生效"
                    log("房间能力切换成功: ${option.title}(${option.roomScenario.value})")
                }

                override fun onError(errorId: Int, e: Exception) {
                    if (!isActiveSession(sessionId)) return
                    _isScenarioUpdating.value = false
                    _statusText.value = "房间能力切换失败: ${e.message}"
                    log("房间能力切换失败: [$errorId] ${e.message}")
                }
            }
        )
    }

    fun updateSpeaker(gender: SpeakerGender) {
        _speakerGender.value = gender
        val currentChannel = channel
        if (currentChannel == null) {
            _statusText.value = "音色已保存，将在创建在线房间时生效"
            log("音色已设置为${speakerLabel(gender)}，将在创建在线房间时生效")
            return
        }
        speakerCancelable?.cancel()
        speakerCancelable = currentChannel.updateSpeaker(
            listOf(TmkSpeaker(SpeakerChannel.LEFT, gender)),
            object : ActionCallback {
                override fun onSuccess(result: Result<Unit>) {
                    _statusText.value = "音色已切换，下一次合成生效"
                    log("音色设置成功: ${speakerLabel(gender)}")
                }

                override fun onError(errorId: Int, e: Exception) {
                    _statusText.value = "音色切换失败: ${e.message}"
                    log("音色设置失败: [$errorId] ${e.message}")
                }
            }
        )
    }

    private fun speakerLabel(gender: SpeakerGender): String = when (gender) {
        SpeakerGender.MALE -> "男声"
        SpeakerGender.FEMALE -> "女声"
    }

    private val listener = object : TmkTranslationListener {
        override fun onRecognized(fromEngine: AbstractChannelEngine?, r: co.timekettle.translation.model.Result<String>?, isFinal: Boolean) {
            Log.d(TAG, DemoTmkResultLogFormatter.makeLine("OnlineListen", "ASR", r, isFinal))
            val text = r?.data ?: ""
            val src = r?.srcCode?.takeIf { it.isNotEmpty() } ?: _sourceLang.value
            val dst = r?.dstCode?.takeIf { it.isNotEmpty() } ?: _targetLang.value
            DemoConversationEventAdapter.makeRecognizedEvent(r, isFinal, src, dst)?.let { bubbleAssembler.consume(it) }
            publishBubbles()
            if (isFinal) log("ASR [final]: $text")
        }
        override fun onTranslate(fromEngine: AbstractChannelEngine?, r: co.timekettle.translation.model.Result<String>?, isFinal: Boolean) {
            Log.d(TAG, DemoTmkResultLogFormatter.makeLine("OnlineListen", "MT", r, isFinal))
            val text = r?.data ?: ""
            val src = r?.srcCode?.takeIf { it.isNotEmpty() } ?: _sourceLang.value
            val dst = r?.dstCode?.takeIf { it.isNotEmpty() } ?: _targetLang.value
            DemoConversationEventAdapter.makeTranslatedEvent(r, isFinal, src, dst)?.let { bubbleAssembler.consume(it) }
            publishBubbles()
            if (isFinal) log("MT [final]: $text")
        }
        override fun onAudioDataReceive(fromEngine: AbstractChannelEngine?, r: co.timekettle.translation.model.Result<String>?, data: ByteArray, channelCount: Int) {
            ttsCoordinator.handleAudioData(r, data, channelCount)
        }
        override fun onError(code: Int, msg: String) {
            val errorText = "翻译错误 [$code]: $msg"
            log(errorText)
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
                log("服务端音频用户离线，等待用户确认是否重新创建通道")
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
                log("网络事件提示: $eventName $status")
                applyRuntimeAction(DemoConversationRuntimeAction.WeakNetwork(status))
                return
            }
            if (eventName == "online_bubble_end") {
                val result = args as? co.timekettle.translation.model.Result<*> ?: return
                val bubbleId = result.bubbleId.takeIf { it.isNotBlank() }
                    ?: result.extraData?.get("bubble_id")?.toString()?.takeIf { it.isNotBlank() }
                    ?: return
                val affectedRows = bubbleAssembler.markBubbleEnded(bubbleId)
                Log.d(TAG, DemoTmkResultLogFormatter.makeBubbleEndLine("OnlineListen", result, affectedRows.size))
                publishBubbles()
                return
            }
            if (eventName == "online_tts_state") {
                applyTtsHighlight(args)
                return
            }
        }

        override fun onStateChanged(fromEngine: AbstractChannelEngine?, snapshot: TmkTranslationChannelStateSnapshot) {
            log("状态变化: ${snapshot.state.rawValue}/${snapshot.reason.rawValue} ${snapshot.message}")
            applySdkChannelSnapshot(snapshot)
        }
    }

    private fun handleRemoteCloseRoom() {
        log("服务端已关闭房间，等待用户确认是否重新创建通道")
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

    /** 可恢复失败后释放旧会话，重新走 SDK 内部的加入通道流程。 */
    private fun recreateChannelAfterRecoverableFailure() {
        val status = "通道可恢复，正在重新加入..."
        stopTranslation(status)
        clearConversation()
        lifecycleGate.reopen()
        initSDK()
    }

    private fun recreateChannelForRoomConfigChange(status: String) {
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
    }

    private fun startRecording(): Boolean {
        if (ContextCompat.checkSelfPermission(application, Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            _statusText.value = "麦克风权限未授权"
            log("没有录音权限")
            return false
        }
        if (isRecording) return true
        val sessionId = pageSessionId.get()
        val bufferSize = AudioRecord.getMinBufferSize(SAMPLE_RATE, CHANNEL_CONFIG, AUDIO_FORMAT)
        audioRecord = AudioRecord(MediaRecorder.AudioSource.MIC, SAMPLE_RATE, CHANNEL_CONFIG, AUDIO_FORMAT, bufferSize)
        isRecording = true; audioRecord?.startRecording(); log("录音已开始")
        _captureSampleRate.value = SAMPLE_RATE
        _captureChannels.value = 1
        vadDetector = VadDetector(sampleRate = SAMPLE_RATE).apply {
            setCallback(object : VadDetector.Callback {
                override fun onVadStart() {
                    log("VAD → 开始说话")
                }
                override fun onVadEnd() { log("VAD → 停止说话") }
            }); init()
        }
        recordingThread = Thread({
            val buf = ByteArray(bufferSize)
            while (isRecording && isActiveSession(sessionId)) {
                val read = audioRecord?.read(buf, 0, buf.size) ?: -1
                if (read > 0) {
                    val data = buf.copyOf(read); vadDetector?.pushAudioBytes(data)
                    channel?.pushStreamAudioData(data, 1, null)
                }
            }
        }, "$TAG-Recorder").apply { start() }
        return true
    }

    fun stopListening() {
        isRecording = false
        vadDetector?.release()
        vadDetector = null
        try { audioRecord?.stop(); audioRecord?.release() } catch (_: Exception) {}
        audioRecord = null
        recordingThread?.interrupt()
        try { recordingThread?.join(300) } catch (_: InterruptedException) {}
        recordingThread = null
        _captureSampleRate.value = 0
        _captureChannels.value = 0
        _playbackChannels.value = 0
        ttsCoordinator.setActive(false)
        ttsCoordinator.release()
        _isStarted.value = false
        _statusText.value = if (channel != null) "收听已停止" else "已停止"
        log("在线收听已停止采集")
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
        stopListening()
        log("录音已停止")
        TmkTranslationSDK.releaseChannel()
        channel = null
        room = null
        _currentRoomNo.value = "-"
        _captureSampleRate.value = 0
        _captureChannels.value = 0
        _playbackChannels.value = 0
        _isLocaleUpdating.value = false
        _isTranslateEngineUpdating.value = false
        ttsCoordinator.setActive(false)
        _isStarted.value = false
        _isStarting.value = false
        _isChannelReady.value = false
        _channelState.value = idleChannelSnapshot
        hasLockedLanguages = false
        pendingSourceLang = null
        pendingTargetLang = null
        _statusText.value = finalStatus
        log("翻译已停止")
    }

    override fun onCleared() { super.onCleared(); stopTranslation() }
}
