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
    private var vadDetector: VadDetector? = null
    private val bubbleManager = OnlineBubbleManager()
    private val networkEventPolicy = DemoOnlineNetworkEventPolicy()

    @Volatile private var isRecording = false
    @Volatile private var released = false
    private val pageSessionId = AtomicInteger(0)
    private val isPreparingChannel = java.util.concurrent.atomic.AtomicBoolean(false)
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
    private val _isStarting = MutableStateFlow(false)
    val isStarting: StateFlow<Boolean> = _isStarting.asStateFlow()
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
    private val _speakerGender = MutableStateFlow(SpeakerGender.FEMALE)
    val speakerGender: StateFlow<SpeakerGender> = _speakerGender.asStateFlow()
    private var hasLockedLanguages = false

    private fun log(msg: String) = Log.d(TAG, msg)

    private fun publishBubbles() { _bubbles.value = bubbleManager.snapshot() }


    fun setLanguagesIfNeeded(sourceLang: String, targetLang: String) {
        if (hasLockedLanguages) return
        _sourceLang.value = sourceLang; _targetLang.value = targetLang; hasLockedLanguages = true
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

    fun initSDK() {
        try {
            if (!_isInitialized.value) {
                TmkTranslationSDK.sdkInit(application, SampleSdkConfig.globalConfig())
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
        if (!_isInitialized.value || channel == null || !isSdkChannelReady()) {
            if (channel != null && canRetrySdkChannel()) {
                _statusText.value = "通道可恢复，正在重新连接..."
                channel?.start()
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
        _statusText.value = "正在收听中..."
        log("在线收听已开始采集")
    }

    private fun prepareChannelIfNeeded(sessionId: Int = pageSessionId.get()) {
        if (channel != null || !isPreparingChannel.compareAndSet(false, true)) return
        released = false
        _statusText.value = "正在鉴权..."
        log("开始鉴权...")
        TmkTranslationSDK.verifyAuth(object : AuthCallback {
            override fun onSuccess() {
                if (!isActiveSession(sessionId)) { isPreparingChannel.set(false); return }
                _statusText.value = "鉴权成功，准备创建房间..."
                log("鉴权成功"); doStart(sessionId)
            }
            override fun onError(errorId: Int, e: Exception) {
                isPreparingChannel.set(false)
                if (!isActiveSession(sessionId)) return
                log("鉴权失败: [$errorId] ${e.message}")
                _statusText.value = "鉴权失败: ${e.message}"
            }
        })
    }

    private fun doStart(sessionId: Int) {
        _statusText.value = "正在创建房间..."
        TmkTranslationSDK.createTmkTranslationRoom(object : CreateRoomCallback {
            override fun onSuccess(room: TmkTranslationRoom) {
                if (!isActiveSession(sessionId)) { isPreparingChannel.set(false); return }
                this@OnlineListenViewModel.room = room
                _currentRoomNo.value = room.roomId
                _statusText.value = "房间已创建，正在创建通道..."
                log("创建房间成功: ${room.roomId}")
                val cfg = TmkTransChannelConfig.Builder()
                    .setRoom(room).setMode(TranslationMode.ONLINE).setTransModeType(TransModeType.LISTEN)
                    .setSourceLang(_sourceLang.value).setTargetLang(_targetLang.value)
                    .setSpeakers(listOf(TmkSpeaker(SpeakerChannel.LEFT, _speakerGender.value)))
                    .setSampleRate(SAMPLE_RATE).setChannelNum(1).build()
                TmkTranslationSDK.createTranslationChannel(application, cfg, listener, object : CreateChannelCallback {
                    override fun onSuccess(ch: TmkTranslationChannel) {
                        if (!isActiveSession(sessionId)) {
                            ch.stop(); ch.destroy()
                            isPreparingChannel.set(false)
                            return
                        }
                        channel = ch
                        isPreparingChannel.set(false)
                        log("Channel 已就绪")
                    }
                    override fun onError(errorId: Int, e: Exception) {
                        isPreparingChannel.set(false)
                        if (!isActiveSession(sessionId)) return
                        log("创建 Channel 失败: [$errorId] ${e.message}")
                        _statusText.value = "通道启动失败: ${e.message}"
                    }
                })
            }
            override fun onError(errorId: Int, e: Exception) {
                isPreparingChannel.set(false)
                if (!isActiveSession(sessionId)) return
                log("创建房间失败: [$errorId] ${e.message}")
                _statusText.value = "房间创建失败: ${e.message}"
            }
        })
    }

    fun updateRoomLocale(sourceLang: String, targetLang: String) {
        val sessionId = pageSessionId.get()
        val currentRoom = room
        if (currentRoom == null) {
            _sourceLang.value = sourceLang
            _targetLang.value = targetLang
            _statusText.value = "语言已切换，将在创建房间时生效"
            log("语言已设置为 $sourceLang -> $targetLang，将在创建房间时生效")
            return
        }
        if (_isLocaleUpdating.value) return
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
                }

                override fun onError(errorId: Int, e: Exception) {
                    if (!isActiveSession(sessionId)) return
                    _isLocaleUpdating.value = false
                    _statusText.value = "语言切换失败: ${e.message}"
                    log("语言切换失败: [$errorId] ${e.message}")
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
            val text = r?.data ?: ""; val bid = bubbleManager.extractBubbleId(r)
            val sid = r?.sessionId ?: ""
            val src = r?.srcCode?.takeIf { it.isNotEmpty() } ?: _sourceLang.value
            val dst = r?.dstCode?.takeIf { it.isNotEmpty() } ?: _targetLang.value
            bubbleManager.upsertSource(sid, bid, src, dst, text, isFinal)
            publishBubbles()
            if (isFinal) log("ASR [final]: $text")
        }
        override fun onTranslate(fromEngine: AbstractChannelEngine?, r: co.timekettle.translation.model.Result<String>?, isFinal: Boolean) {
            val text = r?.data ?: ""; val bid = bubbleManager.extractBubbleId(r)
            val sid = r?.sessionId ?: ""
            val src = r?.srcCode?.takeIf { it.isNotEmpty() } ?: _sourceLang.value
            val dst = r?.dstCode?.takeIf { it.isNotEmpty() } ?: _targetLang.value
            bubbleManager.upsertTranslation(sid, bid, src, dst, text, isFinal)
            publishBubbles()
            if (isFinal) log("MT [final]: $text")
        }
        override fun onAudioDataReceive(fromEngine: AbstractChannelEngine?, r: co.timekettle.translation.model.Result<String>?, data: ByteArray, channelCount: Int) {
            _playbackChannels.value = channelCount
            playTtsAudio(data, channelCount)
        }
        override fun onError(code: Int, msg: String) {
            val errorText = "翻译错误 [$code]: $msg"
            log(errorText)
            showConversationErrorPrompt(OnlineConversationErrorPrompts.fromCode(code, msg))
            stopListening()
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
                _statusText.value = status
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
                override fun onVadStart() { log("VAD → 开始说话") }
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
        stopTtsPlayback()
        _isStarted.value = false
        _statusText.value = if (channel != null) "收听已停止" else "已停止"
        log("在线收听已停止采集")
    }

    fun stopTranslation(finalStatus: String = "已停止收听") {
        released = true
        nextPageSession()
        isPreparingChannel.set(false)
        stopListening()
        speakerCancelable?.cancel()
        speakerCancelable = null
        log("录音已停止")
        channel?.destroy(); channel = null
        room = null
        _currentRoomNo.value = "-"
        _captureSampleRate.value = 0
        _captureChannels.value = 0
        _playbackChannels.value = 0
        _isLocaleUpdating.value = false
        stopTtsPlayback()
        _isStarted.value = false
        _isStarting.value = false
        _isChannelReady.value = false
        _channelState.value = idleChannelSnapshot
        hasLockedLanguages = false
        _statusText.value = finalStatus
        log("翻译已停止")
    }

    override fun onCleared() { super.onCleared(); stopTranslation() }
}
