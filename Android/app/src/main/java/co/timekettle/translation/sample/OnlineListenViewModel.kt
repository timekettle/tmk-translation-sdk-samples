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
import co.timekettle.offlinesdk.vad.VadDetector
import co.timekettle.translation.TmkTranslationChannel
import co.timekettle.translation.TmkTranslationSDK
import co.timekettle.translation.config.TmkTransChannelConfig
import co.timekettle.translation.core.AbstractChannelEngine
import co.timekettle.translation.enums.TranslationMode
import co.timekettle.translation.lingcast.common.enums.TransModeType
import co.timekettle.translation.listener.AuthCallback
import co.timekettle.translation.listener.CreateChannelCallback
import co.timekettle.translation.listener.CreateRoomCallback
import co.timekettle.translation.listener.TmkTranslationListener
import co.timekettle.translation.model.BubbleRowData
import co.timekettle.translation.model.OnlineBubbleManager
import co.timekettle.translation.model.TmkTranslationRoom
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
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
    }

    private var channel: TmkTranslationChannel? = null
    private var audioRecord: AudioRecord? = null
    private var audioTrack: AudioTrack? = null
    private var vadDetector: VadDetector? = null
    private val bubbleManager = OnlineBubbleManager()

    private var currentTraceId: String? = null
    private var vadStartTimeMs: Long = 0
    private var firstAsrTimeMs: Long = 0
    private var firstMtTimeMs: Long = 0
    private var firstTtsTimeMs: Long = 0
    @Volatile private var pendingMetadata: ByteArray? = null
    @Volatile private var isRecording = false
    @Volatile private var released = false

    private val _isInitialized = MutableStateFlow(false)
    val isInitialized: StateFlow<Boolean> = _isInitialized.asStateFlow()
    private val _initErrorMessage = MutableStateFlow<String?>(null)
    val initErrorMessage: StateFlow<String?> = _initErrorMessage.asStateFlow()
    private val _isStarted = MutableStateFlow(false)
    val isStarted: StateFlow<Boolean> = _isStarted.asStateFlow()
    private val _isStarting = MutableStateFlow(false)
    val isStarting: StateFlow<Boolean> = _isStarting.asStateFlow()
    private val _bubbles = MutableStateFlow<List<BubbleRowData>>(emptyList())
    val bubbles: StateFlow<List<BubbleRowData>> = _bubbles.asStateFlow()
    private val _sourceLang = MutableStateFlow("zh-CN")
    val sourceLang: StateFlow<String> = _sourceLang.asStateFlow()
    private val _targetLang = MutableStateFlow("en-US")
    val targetLang: StateFlow<String> = _targetLang.asStateFlow()
    private var hasLockedLanguages = false

    private fun log(msg: String) = Log.d(TAG, msg)

    private fun publishBubbles() { _bubbles.value = bubbleManager.snapshot() }

    private fun buildMetadataBytes(): ByteArray {
        val sdf = java.text.SimpleDateFormat("HHmmss", java.util.Locale.getDefault())
        val time = sdf.format(java.util.Date())
        return byteArrayOf("1".toByte(), time.substring(0, 2).toByte(), time.substring(2, 4).toByte(), time.substring(4, 6).toByte())
    }
    private fun metadataToTraceId(m: ByteArray) = m[0].toString() + m.drop(1).joinToString("") { String.format("%02d", it) }

    private fun resetTrace() {
        currentTraceId = null; vadStartTimeMs = 0; firstAsrTimeMs = 0; firstMtTimeMs = 0; firstTtsTimeMs = 0; pendingMetadata = null
    }

    fun setLanguagesIfNeeded(sourceLang: String, targetLang: String) {
        if (hasLockedLanguages) return
        _sourceLang.value = sourceLang; _targetLang.value = targetLang; hasLockedLanguages = true
    }

    fun initSDK() {
        try {
            TmkTranslationSDK.sdkInit(application, SampleSdkConfig.globalConfig())
            _isInitialized.value = true
            _initErrorMessage.value = null
            log("SDK 初始化完成")
        } catch (e: Exception) {
            log("SDK 初始化异常: ${e.message}")
            _initErrorMessage.value = SampleSdkConfig.buildInitErrorMessage(e)
            Log.e(TAG, "initSDK failed", e)
        }
    }

    fun dismissInitError() {
        _initErrorMessage.value = null
    }

    fun startTranslation() {
        if (!_isInitialized.value) { log("请先初始化 SDK"); return }
        released = false
        _isStarting.value = true
        log("开始鉴权...")
        TmkTranslationSDK.verifyAuth(object : AuthCallback {
            override fun onSuccess() {
                if (released) { _isStarting.value = false; return }
                log("鉴权成功"); doStart()
            }
            override fun onError(errorId: Int, e: Exception) { log("鉴权失败: [$errorId] ${e.message}"); _isStarting.value = false }
        })
    }

    private fun doStart() {
        TmkTranslationSDK.createTmkTranslationRoom(object : CreateRoomCallback {
            override fun onSuccess(room: TmkTranslationRoom) {
                if (released) { _isStarting.value = false; return }
                log("创建房间成功: ${room.roomId}")
                val cfg = TmkTransChannelConfig.Builder()
                    .setRoom(room).setMode(TranslationMode.ONLINE).setTransModeType(TransModeType.LISTEN)
                    .setSourceLang(_sourceLang.value).setTargetLang(_targetLang.value).setSampleRate(SAMPLE_RATE).setChannelNum(1).build()
                TmkTranslationSDK.createTranslationChannel(application, cfg, object : CreateChannelCallback {
                    override fun onSuccess(ch: TmkTranslationChannel) {
                        if (released) {
                            ch.stop(); ch.destroy()
                            _isStarting.value = false
                            return
                        }
                        channel = ch; ch.setTranslationListener(listener); ch.start()
                        log("Channel 已启动"); startRecording(); _isStarting.value = false; _isStarted.value = true
                    }
                    override fun onError(errorId: Int, e: Exception) { log("创建 Channel 失败: [$errorId] ${e.message}"); _isStarting.value = false }
                })
            }
            override fun onError(errorId: Int, e: Exception) { log("创建房间失败: [$errorId] ${e.message}"); _isStarting.value = false }
        })
    }

    private val listener = object : TmkTranslationListener {
        override fun onRecognized(fromEngine: AbstractChannelEngine?, r: co.timekettle.translation.model.Result<String>?, isFinal: Boolean) {
            val text = r?.data ?: ""; val bid = bubbleManager.extractBubbleId(r)
            val sid = r?.sessionId ?: ""
            val src = r?.srcCode?.takeIf { it.isNotEmpty() } ?: _sourceLang.value
            val dst = r?.dstCode?.takeIf { it.isNotEmpty() } ?: _targetLang.value
            bubbleManager.upsertSource(sid, bid, src, dst, text, isFinal)
            publishBubbles()
            if (isFinal) {
                val now = System.currentTimeMillis(); val tid = currentTraceId
                if (tid != null && firstAsrTimeMs == 0L) { firstAsrTimeMs = now; log("ASR [final]: $text | traceId=$tid ASR=${now - vadStartTimeMs}ms") }
                else log("ASR [final]: $text")
            }
        }
        override fun onTranslate(fromEngine: AbstractChannelEngine?, r: co.timekettle.translation.model.Result<String>?, isFinal: Boolean) {
            val text = r?.data ?: ""; val bid = bubbleManager.extractBubbleId(r)
            val sid = r?.sessionId ?: ""
            val src = r?.srcCode?.takeIf { it.isNotEmpty() } ?: _sourceLang.value
            val dst = r?.dstCode?.takeIf { it.isNotEmpty() } ?: _targetLang.value
            bubbleManager.upsertTranslation(sid, bid, src, dst, text, isFinal)
            publishBubbles()
            if (isFinal) {
                val now = System.currentTimeMillis(); val tid = currentTraceId
                if (tid != null && firstMtTimeMs == 0L) { firstMtTimeMs = now; log("MT [final]: $text | traceId=$tid MT=${now - vadStartTimeMs}ms") }
                else log("MT [final]: $text")
            }
        }
        override fun onAudioDataReceive(fromEngine: AbstractChannelEngine?, r: co.timekettle.translation.model.Result<String>?, data: ByteArray, channelCount: Int) { playTtsAudio(data, channelCount) }
        override fun onError(code: Int, msg: String) { log("Error [$code]: $msg"); stopTranslation() }
        override fun onEvent(eventName: String, args: Any?) {
            if (eventName == "tts_metadata_received") {
                val rid = args as? String ?: return; val now = System.currentTimeMillis()
                if (rid == currentTraceId && firstTtsTimeMs == 0L) {
                    firstTtsTimeMs = now; log("TTS metadata | traceId=$rid 总=${now - vadStartTimeMs}ms ASR=${firstAsrTimeMs - vadStartTimeMs}ms MT=${firstMtTimeMs - vadStartTimeMs}ms")
                }
            }
        }
    }

    private fun startRecording() {
        if (ContextCompat.checkSelfPermission(application, Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) { log("没有录音权限"); return }
        val bufferSize = AudioRecord.getMinBufferSize(SAMPLE_RATE, CHANNEL_CONFIG, AUDIO_FORMAT)
        audioRecord = AudioRecord(MediaRecorder.AudioSource.MIC, SAMPLE_RATE, CHANNEL_CONFIG, AUDIO_FORMAT, bufferSize)
        isRecording = true; audioRecord?.startRecording(); log("录音已开始")
        vadDetector = VadDetector(sampleRate = SAMPLE_RATE).apply {
            setCallback(object : VadDetector.Callback {
                override fun onVadStart() {
                    resetTrace(); val m = buildMetadataBytes(); currentTraceId = metadataToTraceId(m)
                    vadStartTimeMs = System.currentTimeMillis() - (vadDetector?.getVadBeginDurationMs() ?: 0)
                    pendingMetadata = m; log("VAD → 开始说话 traceId=$currentTraceId")
                }
                override fun onVadEnd() { val tid = currentTraceId ?: return; log("VAD → 停止说话 traceId=$tid 持续${System.currentTimeMillis() - vadStartTimeMs}ms") }
            }); init()
        }
        Thread {
            val buf = ByteArray(bufferSize)
            while (isRecording) {
                val read = audioRecord?.read(buf, 0, buf.size) ?: -1
                if (read > 0) {
                    val data = buf.copyOf(read); vadDetector?.pushAudioBytes(data)
                    val extra = pendingMetadata; if (extra != null) pendingMetadata = null
                    channel?.pushStreamAudioData(data, 1, extra)
                }
            }
        }.start()
    }

    private fun playTtsAudio(data: ByteArray, channelCount: Int) {
        try {
            val outCh = if (channelCount == 2) AudioFormat.CHANNEL_OUT_STEREO else AudioFormat.CHANNEL_OUT_MONO
            if (audioTrack == null || audioTrack?.state == AudioTrack.STATE_UNINITIALIZED) {
                audioTrack = AudioTrack.Builder().setAudioFormat(AudioFormat.Builder().setSampleRate(SAMPLE_RATE).setChannelMask(outCh).setEncoding(AUDIO_FORMAT).build())
                    .setBufferSizeInBytes(AudioTrack.getMinBufferSize(SAMPLE_RATE, outCh, AUDIO_FORMAT)).setTransferMode(AudioTrack.MODE_STREAM).build()
                audioTrack?.play()
            }
            audioTrack?.write(data, 0, data.size)
        } catch (e: Exception) { Log.e(TAG, "播放 TTS 异常", e) }
    }

    fun stopTranslation() {
        released = true
        _isStarting.value = false
        isRecording = false; vadDetector?.release(); vadDetector = null
        try { audioRecord?.stop(); audioRecord?.release() } catch (_: Exception) {}
        audioRecord = null; log("录音已停止")
        channel?.destroy(); channel = null
        try { audioTrack?.stop(); audioTrack?.release() } catch (_: Exception) {}
        audioTrack = null; _isStarted.value = false; log("翻译已停止")
    }

    override fun onCleared() { super.onCleared(); stopTranslation() }
}
