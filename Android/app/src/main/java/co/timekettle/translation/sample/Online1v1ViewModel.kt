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
import co.timekettle.translation.enums.Scenario
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
import java.io.InputStream
import java.util.Arrays
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
    }

    private var channel: TmkTranslationChannel? = null
    private var audioRecord: AudioRecord? = null
    private var audioTrack: AudioTrack? = null
    private var leftVadDetector: VadDetector? = null
    private var rightVadDetector: VadDetector? = null
    private var assetPcmStream: InputStream? = null
    @Volatile private var isRecording = false
    @Volatile private var released = false
    private val bubbleManager = OnlineBubbleManager()

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

    private val _isInitialized = MutableStateFlow(false)
    val isInitialized: StateFlow<Boolean> = _isInitialized.asStateFlow()
    private val _isStarted = MutableStateFlow(false)
    val isStarted: StateFlow<Boolean> = _isStarted.asStateFlow()
    private val _isStarting = MutableStateFlow(false)
    val isStarting: StateFlow<Boolean> = _isStarting.asStateFlow()
    private val _logMessages = MutableStateFlow<List<String>>(emptyList())
    val logMessages: StateFlow<List<String>> = _logMessages.asStateFlow()
    private val _bubbles = MutableStateFlow<List<BubbleRowData>>(emptyList())
    val bubbles: StateFlow<List<BubbleRowData>> = _bubbles.asStateFlow()
    private val _useFixedAudio = MutableStateFlow(true)
    val useFixedAudio: StateFlow<Boolean> = _useFixedAudio.asStateFlow()
    private val _sourceLang = MutableStateFlow("zh-CN")
    val sourceLang: StateFlow<String> = _sourceLang.asStateFlow()
    private val _targetLang = MutableStateFlow("en-US")
    val targetLang: StateFlow<String> = _targetLang.asStateFlow()
    private var hasLockedLanguages = false

    fun toggleFixedAudio() { _useFixedAudio.value = !_useFixedAudio.value }
    fun setLanguagesIfNeeded(s: String, t: String) {
        if (hasLockedLanguages) return
        _sourceLang.value = s
        _targetLang.value = t
        hasLockedLanguages = true
    }

    private fun addLog(msg: String) {
        Log.d(TAG, msg)
        _logMessages.value = listOf(msg) + _logMessages.value.take(99)
    }

    private fun publishBubbles() { _bubbles.value = bubbleManager.snapshot() }

    private fun buildMetadataBytes(ch: String): ByteArray {
        val sdf = java.text.SimpleDateFormat("HHmmss", java.util.Locale.getDefault())
        val t = sdf.format(java.util.Date())
        return byteArrayOf(ch.toByte(), t.substring(0, 2).toByte(), t.substring(2, 4).toByte(), t.substring(4, 6).toByte())
    }

    private fun metadataToTraceId(m: ByteArray): String =
        m[0].toString() + m.drop(1).joinToString("") { String.format("%02d", it) }

    fun initSDK() {
        if (_isInitialized.value) return
        try {
            TmkTranslationSDK.sdkInit(application, SampleSdkConfig.globalConfig())
            _isInitialized.value = true
            addLog("SDK 初始化完成")
        } catch (e: Exception) {
            addLog("SDK 初始化异常: ${e.message}")
            Log.e(TAG, "initSDK failed", e)
        }
    }

    fun startTranslation() {
        if (!_isInitialized.value) {
            addLog("请先初始化 SDK")
            return
        }
        released = false
        _isStarting.value = true
        addLog("开始鉴权...")
        TmkTranslationSDK.verifyAuth(object : AuthCallback {
            override fun onSuccess() {
                if (released) { _isStarting.value = false; return }
                addLog("鉴权成功")
                doStart()
            }
            override fun onError(errorId: Int, e: Exception) {
                addLog("鉴权失败: [$errorId] ${e.message}")
                _isStarting.value = false
            }
        })
    }

    private fun doStart() {
        addLog("创建在线 1v1 翻译通道...")

        TmkTranslationSDK.createTmkTranslationRoom(object : CreateRoomCallback {
            override fun onSuccess(room: TmkTranslationRoom) {
                if (released) { _isStarting.value = false; return }
                addLog("创建房间成功: ${room.roomId}")

                val channelConfig = TmkTransChannelConfig.Builder()
                    .setRoom(room)
                    .setMode(TranslationMode.ONLINE)
                    .setScenario(Scenario.ONE_TO_ONE)
                    .setTransModeType(TransModeType.ONE_TO_ONE)
                    .setSourceLang(_sourceLang.value)
                    .setTargetLang(_targetLang.value)
                    .setSampleRate(SAMPLE_RATE)
                    .setChannelNum(2)
                    .build()

                addLog("src=${_sourceLang.value} tgt=${_targetLang.value}")

                TmkTranslationSDK.createTranslationChannel(
                    application,
                    channelConfig,
                    object : CreateChannelCallback {
                        override fun onSuccess(ch: TmkTranslationChannel) {
                            if (released) {
                                ch.stop(); ch.destroy()
                                _isStarting.value = false
                                return
                            }
                            channel = ch
                            addLog("创建在线 1v1 Channel 成功")
                            ch.setTranslationListener(translationListener)
                            ch.start()
                            addLog("在线 1v1 Channel 已启动")
                            startDualChannelStreaming()
                            _isStarting.value = false
                            _isStarted.value = true
                        }

                        override fun onError(errorId: Int, e: Exception) {
                            addLog("创建 Channel 失败: [$errorId] ${e.message}")
                            _isStarting.value = false
                        }
                    }
                )
            }

            override fun onError(errorId: Int, e: Exception) {
                addLog("创建房间失败: [$errorId] ${e.message}")
                _isStarting.value = false
            }
        })
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
            val ch = r?.extraData?.get("channel")?.toString() ?: ""
            val bid = bubbleManager.extractBubbleId(r)
            val sid = r?.sessionId ?: ""
            val src = r?.srcCode?.takeIf { it.isNotEmpty() } ?: _sourceLang.value
            val dst = r?.dstCode?.takeIf { it.isNotEmpty() } ?: _targetLang.value

            bubbleManager.upsertSource(sid, bid, src, dst, text, isFinal, channel = ch)
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
            val text = r?.data ?: ""
            val ch = r?.extraData?.get("channel")?.toString() ?: ""
            val bid = bubbleManager.extractBubbleId(r)
            val sid = r?.sessionId ?: ""
            val src = r?.srcCode?.takeIf { it.isNotEmpty() } ?: _sourceLang.value
            val dst = r?.dstCode?.takeIf { it.isNotEmpty() } ?: _targetLang.value

            bubbleManager.upsertTranslation(sid, bid, src, dst, text, isFinal, channel = ch)
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
            playTtsAudio(data, channelCount)
        }

        override fun onError(code: Int, msg: String) {
            addLog("Error [$code]: $msg")
            stopTranslation()
        }

        override fun onEvent(eventName: String, args: Any?) {
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
    }

    private fun startDualChannelStreaming() {
        if (ContextCompat.checkSelfPermission(application, Manifest.permission.RECORD_AUDIO)
            != PackageManager.PERMISSION_GRANTED
        ) {
            addLog("没有录音权限")
            return
        }

        val bufferSize = AudioRecord.getMinBufferSize(SAMPLE_RATE, CHANNEL_CONFIG, AUDIO_FORMAT)
        audioRecord = AudioRecord(MediaRecorder.AudioSource.MIC, SAMPLE_RATE, CHANNEL_CONFIG, AUDIO_FORMAT, bufferSize)
        isRecording = true
        audioRecord?.startRecording()

        val useFixed = _useFixedAudio.value
        if (useFixed) {
            assetPcmStream = application.assets.open("16k16b_en-US.pcm")
            addLog("双声道推流 (左:麦克风, 右:资产PCM)")
        } else {
            addLog("双声道推流 (左:麦克风, 右:静音)")
        }

        leftVadDetector = VadDetector(sampleRate = SAMPLE_RATE).apply {
            setCallback(object : VadDetector.Callback {
                override fun onVadStart() {
                    val m = buildMetadataBytes("1")
                    leftTraceId = metadataToTraceId(m)
                    leftVadStartMs = System.currentTimeMillis() - (leftVadDetector?.getVadBeginDurationMs() ?: 0)
                    leftFirstAsrMs = 0; leftFirstMtMs = 0; leftFirstTtsMs = 0
                    pendingMetadataLeft = m
                    addLog("VAD L → 开始说话 traceId=$leftTraceId")
                }
                override fun onVadEnd() {
                    val tid = leftTraceId ?: return
                    addLog("VAD L → 停止说话 traceId=$tid 持续${System.currentTimeMillis() - leftVadStartMs}ms")
                }
            })
            init()
        }

        rightVadDetector = VadDetector(sampleRate = SAMPLE_RATE).apply {
            setCallback(object : VadDetector.Callback {
                override fun onVadStart() {
                    val m = buildMetadataBytes("2")
                    rightTraceId = metadataToTraceId(m)
                    rightVadStartMs = System.currentTimeMillis() - (rightVadDetector?.getVadBeginDurationMs() ?: 0)
                    rightFirstAsrMs = 0; rightFirstMtMs = 0; rightFirstTtsMs = 0
                    pendingMetadataRight = m
                    addLog("VAD R → 开始说话 traceId=$rightTraceId")
                }
                override fun onVadEnd() {
                    val tid = rightTraceId ?: return
                    addLog("VAD R → 停止说话 traceId=$tid 持续${System.currentTimeMillis() - rightVadStartMs}ms")
                }
            })
            init()
        }

        Thread {
            val samplesPer20ms = 320
            val bytesPerCh = samplesPer20ms * 2
            val leftBuf = ByteArray(bytesPerCh)
            val rightBuf = ByteArray(bytesPerCh)
            val stereoBuf = ByteArray(bytesPerCh * 2)

            while (isRecording) {
                // 麦克风数据
                var lo = 0
                while (lo < bytesPerCh && isRecording) {
                    val r = audioRecord?.read(leftBuf, lo, bytesPerCh - lo) ?: -1
                    if (r > 0) lo += r
                }

                // 固定音频 or 静音
                if (useFixed) {
                    var ro = 0
                    while (ro < bytesPerCh && isRecording) {
                        val r = assetPcmStream?.read(rightBuf, ro, bytesPerCh - ro) ?: -1
                        if (r == -1) {
                            assetPcmStream?.close()
                            assetPcmStream = application.assets.open("16k16b_en-US.pcm")
                        } else if (r > 0) {
                            ro += r
                        }
                    }
                } else {
                    Arrays.fill(rightBuf, 0.toByte())
                }

                // VAD 检测
                leftVadDetector?.pushAudioBytes(leftBuf)
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

                val extra = pendingMetadataLeft ?: pendingMetadataRight
                if (pendingMetadataLeft != null) pendingMetadataLeft = null
                else if (pendingMetadataRight != null) pendingMetadataRight = null

                channel?.pushStreamAudioData(stereoBuf, 2, extra)
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
        isRecording = false
        leftVadDetector?.release(); leftVadDetector = null
        rightVadDetector?.release(); rightVadDetector = null
        try {
            audioRecord?.stop()
            audioRecord?.release()
        } catch (_: Exception) {}
        audioRecord = null
        try { assetPcmStream?.close() } catch (_: Exception) {}
        assetPcmStream = null
        addLog("录音已停止")

        channel?.destroy()
        channel = null
        try {
            audioTrack?.stop()
            audioTrack?.release()
        } catch (_: Exception) {}
        audioTrack = null
        _isStarted.value = false
        addLog("在线 1v1 翻译已停止")
    }

    override fun onCleared() {
        super.onCleared()
        stopTranslation()
    }
}
