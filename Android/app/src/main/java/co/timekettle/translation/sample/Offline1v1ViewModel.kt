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
import co.timekettle.offlinesdk.ModelPaths
import co.timekettle.offlinesdk.OfflineModelManager
import co.timekettle.offlinesdk.vad.VadDetector
import co.timekettle.translation.TmkTranslationChannel
import co.timekettle.translation.TmkTranslationSDK
import co.timekettle.translation.config.TmkTransChannelConfig
import co.timekettle.translation.core.AbstractChannelEngine
import co.timekettle.translation.enums.Scenario
import co.timekettle.translation.enums.TranslationMode
import co.timekettle.translation.listener.AuthCallback
import co.timekettle.translation.listener.CreateChannelCallback
import co.timekettle.translation.listener.CreateRoomCallback
import co.timekettle.translation.listener.TmkTranslationListener
import co.timekettle.translation.model.BubbleRowData
import co.timekettle.translation.model.OfflineBubbleManager
import co.timekettle.translation.model.TmkTranslationRoom
import co.timekettle.translation.utils.RingBuffer
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.io.InputStream
import java.util.Arrays
import javax.inject.Inject

@HiltViewModel
class Offline1v1ViewModel @Inject constructor(
    private val application: Application
) : ViewModel() {

    companion object {
        private const val TAG = "Offline1v1VM"
        private const val SAMPLE_RATE = 16000
        private const val BYTES_PER_20MS = 320 * 2 // 320 samples * 2 bytes (16-bit PCM)

        val SUPPORTED_LANGUAGES = OfflineListenViewModel.SUPPORTED_LANGUAGES
    }

    private var channel: TmkTranslationChannel? = null
    private var audioRecord: AudioRecord? = null
    private var audioTrack: AudioTrack? = null
    private var assetPcmStream: InputStream? = null
    private var leftVadDetector: VadDetector? = null
    private var rightVadDetector: VadDetector? = null
    @Volatile private var isRecording = false
    @Volatile private var isPlaying = false
    @Volatile private var released = false

    // 左声道 traceId
    private var leftTraceId: String? = null
    private var leftVadStartMs: Long = 0
    private var leftFirstAsrMs: Long = 0
    private var leftFirstMtMs: Long = 0
    private var leftFirstTtsMs: Long = 0

    // 右声道 traceId
    private var rightTraceId: String? = null
    private var rightVadStartMs: Long = 0
    private var rightFirstAsrMs: Long = 0
    private var rightFirstMtMs: Long = 0
    private var rightFirstTtsMs: Long = 0

    // 左右声道 TTS RingBuffer
    private val leftTtsBuffer = RingBuffer(BYTES_PER_20MS * 50)  // ~1秒缓冲
    private val rightTtsBuffer = RingBuffer(BYTES_PER_20MS * 50)

    private val _isModelReady = MutableStateFlow(false)
    val isModelReady: StateFlow<Boolean> = _isModelReady.asStateFlow()

    private val _isDownloading = MutableStateFlow(false)
    val isDownloading: StateFlow<Boolean> = _isDownloading.asStateFlow()

    private val _downloadProgress = MutableStateFlow("")
    val downloadProgress: StateFlow<String> = _downloadProgress.asStateFlow()

    private val _isInitialized = MutableStateFlow(false)
    val isInitialized: StateFlow<Boolean> = _isInitialized.asStateFlow()

    private val _isStarted = MutableStateFlow(false)
    val isStarted: StateFlow<Boolean> = _isStarted.asStateFlow()

    private val _isStarting = MutableStateFlow(false)
    val isStarting: StateFlow<Boolean> = _isStarting.asStateFlow()

    private val _logMessages = MutableStateFlow<List<String>>(emptyList())
    val logMessages: StateFlow<List<String>> = _logMessages.asStateFlow()

    private val bubbleManager = OfflineBubbleManager()
    private val _bubbles = MutableStateFlow<List<BubbleRowData>>(emptyList())
    val bubbles: StateFlow<List<BubbleRowData>> = _bubbles.asStateFlow()

    // 固定音频开关（关闭则该路静音）
    private val _useFixedAudio = MutableStateFlow(true)
    val useFixedAudio: StateFlow<Boolean> = _useFixedAudio.asStateFlow()
    fun toggleFixedAudio() { _useFixedAudio.value = !_useFixedAudio.value }

    // 声道交换：false=左麦右PCM，true=左PCM右麦
    private val _swapChannels = MutableStateFlow(false)
    val swapChannels: StateFlow<Boolean> = _swapChannels.asStateFlow()
    fun toggleSwapChannels() { _swapChannels.value = !_swapChannels.value }

    private val _sourceLang = MutableStateFlow("zh-CN")
    val sourceLang: StateFlow<String> = _sourceLang.asStateFlow()
    private val _targetLang = MutableStateFlow("en-US")
    val targetLang: StateFlow<String> = _targetLang.asStateFlow()
    private var hasLockedLanguages = false

    fun setLanguagesIfNeeded(sourceLang: String, targetLang: String) {
        if (hasLockedLanguages) return
        _sourceLang.value = sourceLang
        _targetLang.value = targetLang
        hasLockedLanguages = true
        refreshModelReady()
    }

    init { refreshModelReady() }

    private fun refreshModelReady() {
        val src = ModelPaths.langToCode(_sourceLang.value)
        val tgt = ModelPaths.langToCode(_targetLang.value)
        _isModelReady.value =
            OfflineModelManager.isLanguagePairReady(application, src, tgt, needMt = true, needTts = true) &&
            OfflineModelManager.isLanguagePairReady(application, tgt, src, needMt = true, needTts = true)
    }

    private fun addLog(msg: String) {
        Log.d(TAG, msg)
        _logMessages.value = listOf(msg) + _logMessages.value.take(99)
    }

    private fun publishBubbles() { _bubbles.value = bubbleManager.snapshot() }

    private fun generateTraceId(ch: String): String {
        val sdf = java.text.SimpleDateFormat("HHmmssSSS", java.util.Locale.getDefault())
        return "O${ch}${sdf.format(java.util.Date())}"
    }

    fun downloadModels() {
        if (_isDownloading.value) return
        _isDownloading.value = true
        _downloadProgress.value = "准备下载..."
        addLog("开始下载 ${TranslationLanguages.displayName(_sourceLang.value)} ↔ ${TranslationLanguages.displayName(_targetLang.value)} 双向模型...")

        Thread {
            val forwardReady = downloadLanguagePair(_sourceLang.value, _targetLang.value, "正向")
            val reverseReady = forwardReady && downloadLanguagePair(_targetLang.value, _sourceLang.value, "反向")
            if (forwardReady && reverseReady) {
                addLog("模型下载完成")
                _isModelReady.value = true
            }
            _downloadProgress.value = ""
            _isDownloading.value = false
        }.start()
    }

    private fun downloadLanguagePair(srcLang: String, targetLang: String, stageLabel: String): Boolean {
        var failed = false
        var lastLoggedPct = -1L
        OfflineModelManager.downloadLanguagePair(
            context = application,
            srcLang = srcLang,
            dstLang = targetLang,
            callback = object : OfflineModelManager.DownloadCallback {
                override fun onProgress(fileName: String, downloaded: Long, total: Long) {
                    val pct = if (total > 0) (downloaded * 100 / total) else 0
                    _downloadProgress.value = "$stageLabel $fileName ${pct}%"
                    if (pct >= lastLoggedPct + 5) {
                        lastLoggedPct = pct
                        addLog("[$stageLabel][$fileName] $pct%")
                    }
                }

                override fun onFileProgress(current: Int, total: Int, fileName: String) {
                    lastLoggedPct = -1L
                    _downloadProgress.value = "$stageLabel ($current/$total) $fileName"
                    addLog("$stageLabel 下载 ($current/$total): $fileName")
                }

                override fun onComplete() = Unit

                override fun onError(message: String) {
                    failed = true
                    _downloadProgress.value = "$stageLabel 下载失败"
                    addLog("$stageLabel 下载失败: $message")
                }
            }
        )
        return !failed
    }

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

    fun start() {
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
        addLog("创建离线 1v1 翻译通道...")

        TmkTranslationSDK.createTmkTranslationRoom(object : CreateRoomCallback {
            override fun onSuccess(room: TmkTranslationRoom) {
                if (released) { _isStarting.value = false; return }
                addLog("创建房间成功: ${room.roomId}")

                val modelRootDir = OfflineModelManager.getModelRootDir(application).absolutePath

                val channelConfig = TmkTransChannelConfig.Builder()
                    .setRoom(room)
                    .setMode(TranslationMode.OFFLINE)
                    .setScenario(Scenario.ONE_TO_ONE)
                    .setSourceLang(_sourceLang.value)
                    .setTargetLang(_targetLang.value)
                    .setSampleRate(SAMPLE_RATE)
                    .setChannelNum(2)
                    .addExtraParams("model_root_dir", modelRootDir)
                    .build()

                addLog("src=${_sourceLang.value} tgt=${_targetLang.value} model_root_dir: $modelRootDir")

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
                            addLog("创建离线 1v1 Channel 成功")
                            ch.setTranslationListener(translationListener)
                            ch.start()
                            addLog("离线 1v1 Channel 已启动")
                            startTtsPlaybackThread()
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

    fun stop() {
        released = true
        stopRecording()
        stopTtsPlayback()
        channel?.stop()
        channel?.destroy()
        channel = null
        _isStarting.value = false
        _isStarted.value = false
        addLog("离线 1v1 翻译已停止")
    }

    private val translationListener = object : TmkTranslationListener {
        override fun onRecognized(fromEngine: AbstractChannelEngine?, r: co.timekettle.translation.model.Result<String>?, isFinal: Boolean) {
            val sid = r?.sessionId ?: ""; val text = r?.data ?: ""
            val ch = r?.extraData?.get("channel")?.toString() ?: ""
            val bid = bubbleManager.extractBubbleId(r)
            val src = r?.srcCode?.takeIf { it.isNotEmpty() } ?: _sourceLang.value
            val dst = r?.dstCode?.takeIf { it.isNotEmpty() } ?: _targetLang.value
            bubbleManager.upsertSource(sid, bid, src, dst, text, isFinal, channel = ch)
            publishBubbles()
            if (!isFinal) return
            val now = System.currentTimeMillis()
            if (ch == "left" && leftTraceId != null && leftFirstAsrMs == 0L) {
                leftFirstAsrMs = now; addLog("ASR [final]:L $text | traceId=$leftTraceId ASR=${now - leftVadStartMs}ms")
            } else if (ch == "right" && rightTraceId != null && rightFirstAsrMs == 0L) {
                rightFirstAsrMs = now; addLog("ASR [final]:R $text | traceId=$rightTraceId ASR=${now - rightVadStartMs}ms")
            } else addLog("ASR [ch=$ch final=$isFinal]: $text")
        }

        override fun onTranslate(fromEngine: AbstractChannelEngine?, r: co.timekettle.translation.model.Result<String>?, isFinal: Boolean) {
            val sid = r?.sessionId ?: ""; val text = r?.data ?: ""
            val ch = r?.extraData?.get("channel")?.toString() ?: ""
            val bid = bubbleManager.extractBubbleId(r)
            val src = r?.srcCode?.takeIf { it.isNotEmpty() } ?: _sourceLang.value
            val dst = r?.dstCode?.takeIf { it.isNotEmpty() } ?: _targetLang.value
            bubbleManager.upsertTranslation(sid, bid, src, dst, text, isFinal, channel = ch)
            publishBubbles()
            if (!isFinal) return
            val now = System.currentTimeMillis()
            if (ch == "left" && leftTraceId != null && leftFirstMtMs == 0L) {
                leftFirstMtMs = now; addLog("MT [final]:L $text | traceId=$leftTraceId MT=${now - leftVadStartMs}ms")
            } else if (ch == "right" && rightTraceId != null && rightFirstMtMs == 0L) {
                rightFirstMtMs = now; addLog("MT [final]:R $text | traceId=$rightTraceId MT=${now - rightVadStartMs}ms")
            } else addLog("MT [ch=$ch final=$isFinal]: $text")
        }

        override fun onAudioDataReceive(fromEngine: AbstractChannelEngine?, r: co.timekettle.translation.model.Result<String>?, data: ByteArray, channelCount: Int) {
            val ch = r?.extraData?.get("channel")?.toString() ?: ""
            val now = System.currentTimeMillis()
            if (ch == "left" && leftTraceId != null && leftFirstTtsMs == 0L && data.isNotEmpty()) {
                leftFirstTtsMs = now; val t = now - leftVadStartMs
                addLog("TTS L 首包 | traceId=$leftTraceId 总=${t}ms ASR=${leftFirstAsrMs - leftVadStartMs}ms MT=${leftFirstMtMs - leftVadStartMs}ms")
            } else if (ch == "right" && rightTraceId != null && rightFirstTtsMs == 0L && data.isNotEmpty()) {
                rightFirstTtsMs = now; val t = now - rightVadStartMs
                addLog("TTS R 首包 | traceId=$rightTraceId 总=${t}ms ASR=${rightFirstAsrMs - rightVadStartMs}ms MT=${rightFirstMtMs - rightVadStartMs}ms")
            }
            when (ch) {
                "left" -> leftTtsBuffer.write(data)
                "right" -> rightTtsBuffer.write(data)
                else -> { leftTtsBuffer.write(data); rightTtsBuffer.write(data) }
            }
        }

        override fun onError(code: Int, msg: String) { addLog("Error [$code]: $msg") }
        override fun onEvent(eventName: String, args: Any?) { addLog("Event: $eventName") }
    }

    /**
     * TTS 播放线程: 每 20ms 从左右 RingBuffer 各取一帧，交织成双声道写入 AudioTrack
     */
    private fun startTtsPlaybackThread() {
        if (isPlaying) return
        isPlaying = true
        leftTtsBuffer.clear()
        rightTtsBuffer.clear()

        Thread {
            val minBuf = AudioTrack.getMinBufferSize(
                SAMPLE_RATE, AudioFormat.CHANNEL_OUT_STEREO, AudioFormat.ENCODING_PCM_16BIT
            )
            audioTrack = AudioTrack.Builder()
                .setAudioFormat(
                    AudioFormat.Builder()
                        .setSampleRate(SAMPLE_RATE)
                        .setChannelMask(AudioFormat.CHANNEL_OUT_STEREO)
                        .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                        .build()
                )
                .setBufferSizeInBytes(minBuf)
                .setTransferMode(AudioTrack.MODE_STREAM)
                .build()
            audioTrack?.play()

            val leftFrame = ByteArray(BYTES_PER_20MS)
            val rightFrame = ByteArray(BYTES_PER_20MS)
            val stereoFrame = ByteArray(BYTES_PER_20MS * 2)
            val samplesPerFrame = BYTES_PER_20MS / 2 // 320 samples

            while (isPlaying) {
                val leftReadable = leftTtsBuffer.readable()
                val rightReadable = rightTtsBuffer.readable()

                if (leftReadable < BYTES_PER_20MS && rightReadable < BYTES_PER_20MS) {
                    // 两个 buffer 都没有足够数据，休眠等待
                    try { Thread.sleep(5) } catch (_: InterruptedException) { break }
                    continue
                }

                // 从左声道 buffer 读取，不足则填零（静音）
                val leftRead = if (leftReadable >= BYTES_PER_20MS) {
                    leftTtsBuffer.read(leftFrame, 0, BYTES_PER_20MS, false)
                } else {
                    leftFrame.fill(0)
                    0
                }

                // 从右声道 buffer 读取，不足则填零（静音）
                val rightRead = if (rightReadable >= BYTES_PER_20MS) {
                    rightTtsBuffer.read(rightFrame, 0, BYTES_PER_20MS, false)
                } else {
                    rightFrame.fill(0)
                    0
                }

                // 至少有一个声道有数据才播放
                if (leftRead > 0 || rightRead > 0) {
                    // 交织成立体声: L0 R0 L1 R1 ...
                    var si = 0
                    for (i in 0 until samplesPerFrame) {
                        val bi = i * 2
                        stereoFrame[si] = leftFrame[bi]
                        stereoFrame[si + 1] = leftFrame[bi + 1]
                        stereoFrame[si + 2] = rightFrame[bi]
                        stereoFrame[si + 3] = rightFrame[bi + 1]
                        si += 4
                    }
                    try {
                        audioTrack?.write(stereoFrame, 0, stereoFrame.size)
                    } catch (e: Exception) {
                        Log.e(TAG, "播放 TTS 异常", e)
                    }
                }
            }

            // 清理
            try {
                audioTrack?.stop()
                audioTrack?.release()
            } catch (_: Exception) {}
            audioTrack = null
        }.start()
    }

    private fun stopTtsPlayback() {
        isPlaying = false
    }

    /**
     * 双声道推流: 左声道=麦克风(中文), 右声道=资产PCM(英文)
     * 跟在线 1v1 demo 一样的模式
     */
    private fun startDualChannelStreaming() {
        if (ContextCompat.checkSelfPermission(application, Manifest.permission.RECORD_AUDIO)
            != PackageManager.PERMISSION_GRANTED
        ) {
            addLog("没有录音权限")
            return
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
        assetPcmStream = application.assets.open("16k16b_en-US.pcm")
        addLog("双声道推流已开始")

        leftVadDetector = VadDetector(sampleRate = SAMPLE_RATE).apply {
            setCallback(object : VadDetector.Callback {
                override fun onVadStart() {
                    leftTraceId = generateTraceId("L"); leftVadStartMs = System.currentTimeMillis() - (leftVadDetector?.getVadBeginDurationMs() ?: 0)
                    leftFirstAsrMs = 0; leftFirstMtMs = 0; leftFirstTtsMs = 0
                    addLog("VAD L → 开始说话 traceId=$leftTraceId")
                }
                override fun onVadEnd() {
                    val tid = leftTraceId ?: return
                    addLog("VAD L → 停止说话 traceId=$tid 持续${System.currentTimeMillis() - leftVadStartMs}ms")
                }
            }); init()
        }
        rightVadDetector = VadDetector(sampleRate = SAMPLE_RATE).apply {
            setCallback(object : VadDetector.Callback {
                override fun onVadStart() {
                    rightTraceId = generateTraceId("R"); rightVadStartMs = System.currentTimeMillis() - (rightVadDetector?.getVadBeginDurationMs() ?: 0)
                    rightFirstAsrMs = 0; rightFirstMtMs = 0; rightFirstTtsMs = 0
                    addLog("VAD R → 开始说话 traceId=$rightTraceId")
                }
                override fun onVadEnd() {
                    val tid = rightTraceId ?: return
                    addLog("VAD R → 停止说话 traceId=$tid 持续${System.currentTimeMillis() - rightVadStartMs}ms")
                }
            }); init()
        }

        Thread {
            val samplesPer20ms = 320
            val bytesPerChannel = samplesPer20ms * 2
            val micBuf = ByteArray(bytesPerChannel)
            val pcmBuf = ByteArray(bytesPerChannel)
            val stereoBuf = ByteArray(bytesPerChannel * 2)

            while (isRecording) {
                // 麦克风数据
                var micOffset = 0
                while (micOffset < bytesPerChannel && isRecording) {
                    val read = audioRecord?.read(micBuf, micOffset, bytesPerChannel - micOffset) ?: -1
                    if (read > 0) micOffset += read
                }

                // 固定音频 or 静音
                if (_useFixedAudio.value) {
                    var pcmOffset = 0
                    while (pcmOffset < bytesPerChannel && isRecording) {
                        val r = assetPcmStream?.read(pcmBuf, pcmOffset, bytesPerChannel - pcmOffset) ?: -1
                        if (r == -1) {
                            assetPcmStream?.close()
                            assetPcmStream = application.assets.open("16k16b_en-US.pcm")
                        } else if (r > 0) {
                            pcmOffset += r
                        }
                    }
                } else {
                    Arrays.fill(pcmBuf, 0.toByte())
                }

                // 根据 swapChannels 决定左右声道内容
                val swap = _swapChannels.value
                val leftBuf = if (swap) pcmBuf else micBuf
                val rightBuf = if (swap) micBuf else pcmBuf

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

                channel?.pushStreamAudioData(stereoBuf, 2, null)
            }
        }.start()
    }

    private fun stopRecording() {
        isRecording = false
        leftVadDetector?.release(); leftVadDetector = null
        rightVadDetector?.release(); rightVadDetector = null
        try {
            audioRecord?.stop()
            audioRecord?.release()
        } catch (_: Exception) {}
        audioRecord = null
        try {
            assetPcmStream?.close()
        } catch (_: Exception) {}
        assetPcmStream = null
    }

    override fun onCleared() {
        super.onCleared()
        stop()
    }
}
