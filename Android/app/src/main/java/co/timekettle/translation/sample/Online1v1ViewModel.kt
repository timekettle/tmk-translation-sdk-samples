package co.timekettle.translation.sample

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
import co.timekettle.translation.TmkTranslationChannel
import co.timekettle.translation.TmkTranslationSDK
import co.timekettle.offlinesdk.vad.VadDetector
import co.timekettle.translation.config.TmkTransChannelConfig
import co.timekettle.translation.config.TmkTransGlobalConfig
import co.timekettle.translation.core.AbstractChannelEngine
import co.timekettle.translation.enums.Scenario
import co.timekettle.translation.enums.TranslationMode
import co.timekettle.translation.lingcast.common.enums.TransModeType
import co.timekettle.translation.listener.ActionCallback
import co.timekettle.translation.listener.AuthCallback
import co.timekettle.translation.listener.CreateChannelCallback
import co.timekettle.translation.listener.CreateRoomCallback
import co.timekettle.translation.listener.TmkTranslationListener
import co.timekettle.translation.model.BubbleRowData
import co.timekettle.translation.model.OnlineBubbleManager
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
import java.io.InputStream
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
    private var speakerCancelable: Cancelable? = null
    private var room: TmkTranslationRoom? = null
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
    private var assetPcmStream: InputStream? = null
    @Volatile private var isRecording = false
    @Volatile private var released = false
    private val pageSessionId = AtomicInteger(0)
    private val isPreparingChannel = java.util.concurrent.atomic.AtomicBoolean(false)
    private var recordingThread: Thread? = null
    private val bubbleManager = OnlineBubbleManager()
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
    private val _isStarting = MutableStateFlow(false)
    val isStarting: StateFlow<Boolean> = _isStarting.asStateFlow()
    private val _logMessages = MutableStateFlow<List<String>>(emptyList())
    val logMessages: StateFlow<List<String>> = _logMessages.asStateFlow()
    private val _bubbles = MutableStateFlow<List<BubbleRowData>>(emptyList())
    val bubbles: StateFlow<List<BubbleRowData>> = _bubbles.asStateFlow()
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
        _isChannelReady.value = when (snapshot.state) {
            TmkTranslationChannelState.RUNNING,
            TmkTranslationChannelState.DEGRADED -> true
            else -> false
        }

        when (snapshot.state) {
            TmkTranslationChannelState.STARTING -> _statusText.value = "通道连接中..."
            TmkTranslationChannelState.RUNNING -> {
                if (!_isStarted.value) _statusText.value = "通道已连接，可以开始收听"
            }
            TmkTranslationChannelState.RECONNECTING -> _statusText.value = "通道重连中..."
            TmkTranslationChannelState.DEGRADED -> _statusText.value = "通道能力受损，仍可继续收听"
            TmkTranslationChannelState.STOPPING -> {
                if (_isStarted.value) stopListening()
                _statusText.value = "通道停止中..."
            }
            TmkTranslationChannelState.STOPPED -> {
                if (_isStarted.value) stopListening()
                if (!_remoteCloseRoomPromptVisible.value) _statusText.value = "通道已停止"
            }
            TmkTranslationChannelState.FAILED -> {
                if (_isStarted.value) stopListening()
                _statusText.value = "通道异常: ${snapshot.message}"
                showConversationErrorPrompt(OnlineConversationErrorPrompts.fromSnapshot(snapshot))
            }
            TmkTranslationChannelState.IDLE -> Unit
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

    private fun publishBubbles() { _bubbles.value = bubbleManager.snapshot() }


    fun initSDK() {
        try {
            if (!_isInitialized.value) {
                TmkTranslationSDK.sdkInit(application, SampleSdkConfig.globalConfig())
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

        TmkTranslationSDK.createTmkTranslationRoom(object : CreateRoomCallback {
            override fun onSuccess(room: TmkTranslationRoom) {
                if (!isActiveSession(sessionId)) { isPreparingChannel.set(false); return }
                this@Online1v1ViewModel.room = room
                _currentRoomNo.value = room.roomId
                _statusText.value = "房间已创建，正在创建通道..."
                addLog("创建房间成功: ${room.roomId}")

                val channelConfig = TmkTransChannelConfig.Builder()
                    .setRoom(room)
                    .setMode(TranslationMode.ONLINE)
                    .setScenario(Scenario.ONE_TO_ONE)
                    .setTransModeType(TransModeType.ONE_TO_ONE)
                    // 对齐 iOS Demo：在线一对一左声道是目标语言侧，右声道是源语言/麦克风侧。
                    .setSourceLang(_targetLang.value)
                    .setTargetLang(_sourceLang.value)
                    .setSpeakers(currentSpeakers())
                    .setSampleRate(SAMPLE_RATE)
                    .setChannelNum(2)
                    .build()

                addLog("left=${_targetLang.value} right=${_sourceLang.value}")

                TmkTranslationSDK.createTranslationChannel(
                    application,
                    channelConfig,
                    translationListener,
                    object : CreateChannelCallback {
                        override fun onSuccess(ch: TmkTranslationChannel) {
                            if (!isActiveSession(sessionId)) {
                                ch.stop(); ch.destroy()
                                isPreparingChannel.set(false)
                                return
                            }
                            channel = ch
                            addLog("创建在线 1v1 Channel 成功")
                            isPreparingChannel.set(false)
                            addLog("在线 1v1 Channel 已就绪")
                        }

                        override fun onError(errorId: Int, e: Exception) {
                            isPreparingChannel.set(false)
                            if (!isActiveSession(sessionId)) return
                            addLog("创建 Channel 失败: [$errorId] ${e.message}")
                            _statusText.value = "通道启动失败: ${e.message}"
                        }
                    }
                )
            }

            override fun onError(errorId: Int, e: Exception) {
                isPreparingChannel.set(false)
                if (!isActiveSession(sessionId)) return
                addLog("创建房间失败: [$errorId] ${e.message}")
                _statusText.value = "房间创建失败: ${e.message}"
            }
        })
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
            val text = r?.data ?: ""
            val ch = normalizeChannel(r?.extraData?.get("channel"))
            val bid = bubbleManager.extractBubbleId(r)
            val sid = r?.sessionId ?: ""
            val (src, dst) = languagePairForChannel(ch)

            bubbleManager.upsertSource(sid, bid, src, dst, text, isFinal, channel = ch)
            publishBubbles()

            if (!isFinal) return

            addLog("ASR [ch=$ch final=$isFinal]: $text")
        }

        override fun onTranslate(
            fromEngine: AbstractChannelEngine?,
            r: co.timekettle.translation.model.Result<String>?,
            isFinal: Boolean
        ) {
            val text = r?.data ?: ""
            val ch = normalizeChannel(r?.extraData?.get("channel"))
            val bid = bubbleManager.extractBubbleId(r)
            val sid = r?.sessionId ?: ""
            val (src, dst) = languagePairForChannel(ch)

            bubbleManager.upsertTranslation(sid, bid, src, dst, text, isFinal, channel = ch)
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
                _statusText.value = status
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
        bubbleManager.clear()
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

        assetPcmStream = application.assets.open("en_simple.pcm")
        addLog("双声道推流 (左:资产PCM, 右:麦克风)")
        _captureSampleRate.value = SAMPLE_RATE
        _captureChannels.value = 2

        rightVadDetector = VadDetector(sampleRate = SAMPLE_RATE).apply {
            setCallback(object : VadDetector.Callback {
                override fun onVadStart() { addLog("VAD R → 开始说话") }
                override fun onVadEnd() { addLog("VAD R → 停止说话") }
            })
            init()
        }

        recordingThread = Thread({
            val samplesPer20ms = 320
            val bytesPerCh = samplesPer20ms * 2
            val leftBuf = ByteArray(bytesPerCh)
            val rightBuf = ByteArray(bytesPerCh)
            val stereoBuf = ByteArray(bytesPerCh * 2)

            while (isRecording && isActiveSession(sessionId)) {
                // 对齐 iOS Demo：左声道固定资产 PCM，右声道麦克风。
                var lo = 0
                while (lo < bytesPerCh && isRecording) {
                    val r = assetPcmStream?.read(leftBuf, lo, bytesPerCh - lo) ?: -1
                    if (r == -1) {
                        assetPcmStream?.close()
                        assetPcmStream = application.assets.open("en_simple.pcm")
                    } else if (r > 0) {
                        lo += r
                    }
                }

                var ro = 0
                while (ro < bytesPerCh && isRecording) {
                    val r = audioRecord?.read(rightBuf, ro, bytesPerCh - ro) ?: -1
                    if (r > 0) ro += r
                }

                // 对齐 iOS Demo：在线一对一只用右声道麦克风触发 VAD。
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
        try { assetPcmStream?.close() } catch (_: Exception) {}
        assetPcmStream = null
        _captureSampleRate.value = 0
        _captureChannels.value = 0
        _playbackChannels.value = 0
        stopTtsPlayback()
    }

    fun stopTranslation(finalStatus: String = "已停止收听") {
        released = true
        nextPageSession()
        isPreparingChannel.set(false)
        stopAudioCapture()
        speakerCancelable?.cancel()
        speakerCancelable = null
        addLog("录音已停止")

        channel?.destroy()
        channel = null
        room = null
        _currentRoomNo.value = "-"
        _isLocaleUpdating.value = false
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
