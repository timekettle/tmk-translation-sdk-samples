package co.timekettle.translation.sample
import co.timekettle.translation.TmkTranslationChannel
import co.timekettle.translation.TmkTranslationSDK

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
import co.timekettle.translation.Cancelable
import co.timekettle.offlinesdk.vad.VadDetector
import co.timekettle.translation.config.TmkCreateChannelOptions
import co.timekettle.translation.config.TmkTransChannelConfig
import co.timekettle.translation.config.TmkTransGlobalConfig
import co.timekettle.translation.config.TmkTranslationRoomConfig
import co.timekettle.translation.core.AbstractChannelEngine
import co.timekettle.translation.enums.Scenario
import co.timekettle.translation.enums.TmkOnlineTranslateEngine
import co.timekettle.translation.enums.TranslationMode
import co.timekettle.translation.lingcast.common.enums.TransModeType
import co.timekettle.translation.listener.ActionCallback
import co.timekettle.translation.listener.AuthCallback
import co.timekettle.translation.listener.CreateChannelCallback
import co.timekettle.translation.listener.CreateRoomCallback
import co.timekettle.translation.listener.TmkTranslationListener
import co.timekettle.translation.model.Result
import co.timekettle.translation.model.SpeakerChannel
import co.timekettle.translation.model.SpeakerGender
import co.timekettle.translation.model.TmkSpeaker
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
        private const val PCM_16BIT_BYTES = 2
        private const val TTS_QUEUE_MAX_MS = 1_000
        private const val TTS_QUEUE_TARGET_MS = 300
    }

    private data class TtsFrame(val data: ByteArray, val channelCount: Int)

    private var channel: TmkTranslationChannel? = null
    private var room: TmkTranslationRoom? = null
    private var roomCancelable: Cancelable? = null
    private var channelCancelable: Cancelable? = null
    private var speakerCancelable: Cancelable? = null
    private var audioRecord: AudioRecord? = null
    private var audioTrack: AudioTrack? = null
    private var audioTrackChannelCount: Int = 0
    private val ttsQueueLock = Object()
    private val ttsQueue = java.util.ArrayDeque<TtsFrame>()
    private var ttsQueuedBytes: Int = 0
    private var queuedTtsChannelCount: Int = 0
    private var ttsPlayerThread: Thread? = null
    @Volatile private var isTtsPlayerRunning = false
    private var leftVadDetector: VadDetector? = null
    private var rightVadDetector: VadDetector? = null
    @Volatile private var isRecording = false
    @Volatile private var released = false
    private val pageSessionId = AtomicInteger(0)
    private val isPreparingChannel = java.util.concurrent.atomic.AtomicBoolean(false)
    private var recordingThread: Thread? = null
    private val bubbleAssembler = DemoConversationBubbleAssembler()
    /** 当前应高亮的 session_id（源文蓝色），由 online_tts_state.is_end 控制。 */
    private val blueSessions = mutableSetOf<String>()
    /** 当前应高亮的 chunk_id（译文蓝色），由 online_tts_state.is_end 控制。 */
    private val blueChunks = mutableSetOf<String>()
    private val networkEventPolicy = DemoOnlineNetworkEventPolicy()

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
    private val _onlineTranslateEngine = MutableStateFlow(TmkOnlineTranslateEngine.FAST)
    val onlineTranslateEngine: StateFlow<TmkOnlineTranslateEngine> = _onlineTranslateEngine.asStateFlow()
    private val _roomScenarioOption = MutableStateFlow(OnlineRoomScenarioOption.defaultOption)
    val roomScenarioOption: StateFlow<OnlineRoomScenarioOption> = _roomScenarioOption.asStateFlow()
    private var hasLockedLanguages = false

    fun setLanguagesIfNeeded(s: String, t: String) {
        if (hasLockedLanguages) return
        _sourceLang.value = s
        _targetLang.value = t
        hasLockedLanguages = true
    }

    private fun nextPageSession(): Int = pageSessionId.incrementAndGet()

    private fun isActiveSession(sessionId: Int): Boolean = !released && pageSessionId.get() == sessionId

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
        _bubbles.value = bubbleAssembler.snapshotWithSegments().map { snapshot ->
            DemoConversationHighlighter.applyHighlight(snapshot, blueSessions, blueChunks)
        }
    }

    /**
     * 收到 online_tts_state：按 is_end 着色（false→蓝，true→默认）。
     * 源文按 session_id 命中、译文按 chunk_id 命中，随后重渲染所有气泡。
     */
    private fun applyTtsHighlight(args: Any?) {
        val result = args as? Result<*> ?: return
        val isEnd = (result.extraData?.get("is_end") as? Boolean) ?: result.isLast
        val sessionId = result.sessionId.takeIf { it.isNotBlank() }
        val chunkId = result.extraData?.get("chunk_id")?.toString()?.takeIf { it.isNotBlank() }
        if (isEnd) {
            sessionId?.let { blueSessions.remove(it) }
            chunkId?.let { blueChunks.remove(it) }
        } else {
            sessionId?.let { blueSessions.add(it) }
            chunkId?.let { blueChunks.add(it) }
        }
        publishBubbles()
    }

    fun initSDK() {
        try {
            if (!_isInitialized.value) {
                TmkTranslationSDK.sdkInit(application, SampleSdkConfig.globalConfig(application))
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
        if (channel != null || !isPreparingChannel.compareAndSet(false, true)) return
        released = false
        _statusText.value = "正在鉴权..."
        addLog("开始鉴权...")
        TmkTranslationSDK.verifyAuth(object : AuthCallback {
            override fun onSuccess() {
                if (!isActiveSession(sessionId)) { isPreparingChannel.set(false); return }
                _statusText.value = "鉴权成功，准备创建房间..."
                addLog("鉴权成功")
                doStart(sessionId)
            }
            override fun onError(errorId: Int, e: Exception) {
                isPreparingChannel.set(false)
                if (!isActiveSession(sessionId)) return
                addLog("鉴权失败: [$errorId] ${e.message}")
                _statusText.value = "鉴权失败: ${e.message}"
            }
        })
    }

    private fun doStart(sessionId: Int) {
        addLog("创建在线 1v1 翻译通道...")
        _statusText.value = "正在创建房间..."

        roomCancelable?.cancel()
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
                addLog("创建房间成功: ${room.roomId}")

                val channelConfig = buildOnlineChannelConfig(room)

                addLog("left=${_targetLang.value} right=${_sourceLang.value}")

                channelCancelable?.cancel()
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
                            addLog("在线 1v1 Channel 已就绪")
                        }

                        override fun onError(errorId: Int, e: Exception) {
                            channelCancelable = null
                            isPreparingChannel.set(false)
                            if (!isActiveSession(sessionId)) return
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
            _playbackChannels.value = channelCount
            playTtsAudio(data, channelCount)
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
        released = false
        initSDK()
    }

    fun dismissRemoteCloseRoomPrompt() {
        _remoteCloseRoomPromptVisible.value = false
        _conversationErrorPrompt.value = null
    }

    private fun clearConversation() {
        bubbleAssembler.clear()
        blueSessions.clear()
        blueChunks.clear()
        _bubbles.value = emptyList()
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
                    addLog("VAD R → 开始说话")
                }
                override fun onVadEnd() {
                    addLog("VAD R → 停止说话")
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
                leftLoopBuffer.fillNextLoopChunk(leftBuf)

                var ro = 0
                while (ro < bytesPerCh && isRecording) {
                    val r = audioRecord?.read(rightBuf, ro, bytesPerCh - ro) ?: -1
                    if (r > 0) ro += r
                }

                // 对齐 iOS Demo：在线一对一只用右声道麦克风做 VAD 检测。
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

                channel?.pushStreamAudioData(stereoBuf, 2, null)
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

    private fun playTtsAudio(data: ByteArray, channelCount: Int) {
        if (data.isEmpty()) return
        val safeChannelCount = if (channelCount == 2) 2 else 1
        synchronized(ttsQueueLock) {
            if (queuedTtsChannelCount != 0 && queuedTtsChannelCount != safeChannelCount) {
                clearTtsQueueLocked()
            }
            queuedTtsChannelCount = safeChannelCount
            ensureTtsPlayerThreadLocked()
            ttsQueue.addLast(TtsFrame(data.copyOf(), safeChannelCount))
            ttsQueuedBytes += data.size
            trimTtsQueueLocked(safeChannelCount)
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
                    if (ttsQueue.isEmpty()) queuedTtsChannelCount = 0
                    next
                }
            } ?: break

            writeTtsFrame(frame)
        }
    }

    private fun writeTtsFrame(frame: TtsFrame) {
        try {
            val track = ensureTtsAudioTrack(frame.channelCount) ?: return
            var offset = 0
            while (offset < frame.data.size && isTtsPlayerRunning) {
                val written = track.write(frame.data, offset, frame.data.size - offset)
                if (written > 0) {
                    offset += written
                } else if (written < 0) {
                    Log.e(TAG, "播放 TTS 写入失败: $written")
                    break
                }
            }
        } catch (e: Exception) { Log.e(TAG, "播放 TTS 异常", e) }
    }

    private fun ensureTtsAudioTrack(channelCount: Int): AudioTrack? {
        val existing = audioTrack
        if (existing != null &&
            audioTrackChannelCount == channelCount &&
            existing.state != AudioTrack.STATE_UNINITIALIZED
        ) {
            return existing
        }

        releaseTtsAudioTrack()
        val outCh = if (channelCount == 2) AudioFormat.CHANNEL_OUT_STEREO else AudioFormat.CHANNEL_OUT_MONO
        val minBufferSize = AudioTrack.getMinBufferSize(SAMPLE_RATE, outCh, AUDIO_FORMAT).coerceAtLeast(0)
        val bufferSize = maxOf(minBufferSize, ttsBytesForMs(channelCount, 200))
        audioTrack = AudioTrack.Builder()
            .setAudioFormat(
                AudioFormat.Builder()
                    .setSampleRate(SAMPLE_RATE)
                    .setChannelMask(outCh)
                    .setEncoding(AUDIO_FORMAT)
                    .build()
            )
            .setBufferSizeInBytes(bufferSize)
            .setTransferMode(AudioTrack.MODE_STREAM)
            .build()
        audioTrackChannelCount = channelCount
        audioTrack?.play()
        return audioTrack
    }

    private fun trimTtsQueueLocked(channelCount: Int) {
        val maxBytes = ttsBytesForMs(channelCount, TTS_QUEUE_MAX_MS)
        if (ttsQueuedBytes <= maxBytes) return
        val targetBytes = ttsBytesForMs(channelCount, TTS_QUEUE_TARGET_MS)
        var droppedBytes = 0
        while (ttsQueue.size > 1 && ttsQueuedBytes > targetBytes) {
            val dropped = ttsQueue.removeFirst()
            ttsQueuedBytes -= dropped.data.size
            droppedBytes += dropped.data.size
        }
        if (droppedBytes > 0) {
            Log.w(TAG, "TTS 队列过长，丢弃旧音频约 ${ttsDurationMs(droppedBytes, channelCount)}ms")
        }
    }

    private fun clearTtsQueueLocked() {
        ttsQueue.clear()
        ttsQueuedBytes = 0
        queuedTtsChannelCount = 0
    }

    private fun ttsBytesForMs(channelCount: Int, ms: Int): Int =
        SAMPLE_RATE * channelCount * PCM_16BIT_BYTES * ms / 1_000

    private fun ttsDurationMs(bytes: Int, channelCount: Int): Long {
        val bytesPerSecond = SAMPLE_RATE * channelCount * PCM_16BIT_BYTES
        return if (bytesPerSecond > 0) bytes * 1_000L / bytesPerSecond else 0L
    }

    private fun stopTtsPlayback() {
        synchronized(ttsQueueLock) {
            isTtsPlayerRunning = false
            clearTtsQueueLocked()
            ttsQueueLock.notifyAll()
        }
        ttsPlayerThread?.interrupt()
        ttsPlayerThread = null
        releaseTtsAudioTrack()
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
        audioTrackChannelCount = 0
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
        stopTtsPlayback()
    }

    fun stopTranslation(finalStatus: String = "已停止收听") {
        released = true
        nextPageSession()
        isPreparingChannel.set(false)
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
