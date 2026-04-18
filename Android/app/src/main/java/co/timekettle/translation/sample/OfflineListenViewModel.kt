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
import co.timekettle.translation.enums.TranslationMode
import co.timekettle.translation.lingcast.common.enums.TransModeType
import co.timekettle.translation.listener.AuthCallback
import co.timekettle.translation.listener.CreateChannelCallback
import co.timekettle.translation.listener.CreateRoomCallback
import co.timekettle.translation.listener.TmkTranslationListener
import co.timekettle.translation.model.BubbleRowData
import co.timekettle.translation.model.OfflineBubbleManager
import co.timekettle.translation.model.TmkTranslationRoom
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import javax.inject.Inject

@HiltViewModel
class OfflineListenViewModel @Inject constructor(
    private val application: Application
) : ViewModel() {

    companion object {
        private const val TAG = "OfflineListenVM"
        private const val SAMPLE_RATE = 16000

        /** 离线支持的语言列表 (BCP-47 → 显示名) */
        val SUPPORTED_LANGUAGES = TranslationLanguages.offline
    }

    private var channel: TmkTranslationChannel? = null
    private var audioRecord: AudioRecord? = null
    private var audioTrack: AudioTrack? = null
    private var vadDetector: VadDetector? = null
    @Volatile private var isRecording = false
    @Volatile private var released = false

    // traceId 计时
    private var currentTraceId: String? = null
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
        _isModelReady.value = OfflineModelManager.isLanguagePairReady(
            application, src, tgt, needMt = true, needTts = true
        )
    }

    private fun addLog(msg: String) {
        Log.d(TAG, msg)
        _logMessages.value = listOf(msg) + _logMessages.value.take(99)
    }

    private fun publishBubbles() { _bubbles.value = bubbleManager.snapshot() }

    private fun generateTraceId(): String {
        val sdf = java.text.SimpleDateFormat("HHmmssSSS", java.util.Locale.getDefault())
        return "OL${sdf.format(java.util.Date())}"
    }

    private fun resetTrace() {
        currentTraceId = null; vadStartMs = 0; firstAsrMs = 0; firstMtMs = 0; firstTtsMs = 0
    }

    fun downloadModels() {
        if (_isDownloading.value) return
        _isDownloading.value = true
        _downloadProgress.value = "准备下载..."
        addLog("开始下载 ${TranslationLanguages.displayName(_sourceLang.value)} → ${TranslationLanguages.displayName(_targetLang.value)} 模型...")

        var lastLoggedPct = -1L
        var currentFileIdx = 0
        var totalFiles = 0
        Thread {
            OfflineModelManager.downloadLanguagePair(
                context = application,
                srcLang = _sourceLang.value,
                dstLang = _targetLang.value,
                callback = object : OfflineModelManager.DownloadCallback {
                override fun onProgress(fileName: String, downloaded: Long, total: Long) {
                    val pct = if (total > 0) (downloaded * 100 / total) else 0
                    val fileLabel = if (totalFiles > 0) "($currentFileIdx/$totalFiles) " else ""
                    _downloadProgress.value = "$fileLabel$fileName ${pct}%"
                    if (pct >= lastLoggedPct + 5) {
                        lastLoggedPct = pct
                        addLog("[$fileName] $pct%")
                    }
                }
                override fun onFileProgress(current: Int, total: Int, fileName: String) {
                    currentFileIdx = current
                    totalFiles = total
                    lastLoggedPct = -1L
                    _downloadProgress.value = "($current/$total) $fileName"
                    addLog("下载 ($current/$total): $fileName")
                }
                override fun onComplete() {
                    addLog("模型下载完成")
                    _downloadProgress.value = ""
                    _isModelReady.value = true
                    _isDownloading.value = false
                }
                override fun onError(message: String) {
                    addLog("下载失败: $message")
                    _downloadProgress.value = "下载失败"
                    _isDownloading.value = false
                }
            })
        }.start()
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
        try {
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
        } catch (e: Exception) {
            addLog("鉴权异常: ${e.message}")
            Log.e(TAG, "verifyAuth failed", e)
            _isStarting.value = false
        }
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
                        val modelRootDir = OfflineModelManager.getModelRootDir(application).absolutePath

                        val channelConfig = TmkTransChannelConfig.Builder()
                            .setRoom(room)
                            .setMode(TranslationMode.OFFLINE)
                            .setTransModeType(TransModeType.LISTEN)
                            .setSourceLang(_sourceLang.value)
                            .setTargetLang(_targetLang.value)
                            .setSampleRate(SAMPLE_RATE)
                            .setChannelNum(1)
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
                                    try {
                                        channel = ch
                                        addLog("创建离线 Channel 成功")
                                        ch.setTranslationListener(translationListener)
                                        ch.start()
                                        addLog("离线 Channel 已启动")
                                        startRecording()
                                        _isStarting.value = false
                                        _isStarted.value = true
                                    } catch (e: Exception) {
                                        addLog("启动离线 Channel 异常: ${e.message}")
                                        Log.e(TAG, "start channel failed", e)
                                        channel = null
                                        _isStarting.value = false
                                    }
                                }

                                override fun onError(errorId: Int, e: Exception) {
                                    addLog("创建 Channel 失败: [$errorId] ${e.message}")
                                    _isStarting.value = false
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

    fun stop() {
        released = true
        stopRecording()
        channel?.stop()
        channel?.destroy()
        channel = null
        try {
            audioTrack?.stop()
            audioTrack?.release()
        } catch (_: Exception) {}
        audioTrack = null
        _isStarting.value = false
        _isStarted.value = false
        addLog("离线翻译已停止")
    }

    private val translationListener = object : TmkTranslationListener {
        override fun onRecognized(fromEngine: AbstractChannelEngine?, r: co.timekettle.translation.model.Result<String>?, isFinal: Boolean) {
            val sid = r?.sessionId ?: ""; val text = r?.data ?: ""
            val bid = bubbleManager.extractBubbleId(r)
            val src = r?.srcCode?.takeIf { it.isNotEmpty() } ?: _sourceLang.value
            val dst = r?.dstCode?.takeIf { it.isNotEmpty() } ?: _targetLang.value
            Log.d(TAG, "onRecognized: sid=$sid bid=$bid isFinal=$isFinal text=\"$text\"")
            bubbleManager.upsertSource(sid, bid, src, dst, text, isFinal)
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
            val sid = r?.sessionId ?: ""; val text = r?.data ?: ""
            val bid = bubbleManager.extractBubbleId(r)
            val src = r?.srcCode?.takeIf { it.isNotEmpty() } ?: _sourceLang.value
            val dst = r?.dstCode?.takeIf { it.isNotEmpty() } ?: _targetLang.value
            Log.d(TAG, "onTranslate: sid=$sid bid=$bid isFinal=$isFinal text=\"$text\"")
            bubbleManager.upsertTranslation(sid, bid, src, dst, text, isFinal)
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
            playTtsAudio(data)
        }

        override fun onError(code: Int, msg: String) { addLog("Error [$code]: $msg") }
        override fun onEvent(eventName: String, args: Any?) { addLog("Event: $eventName") }
    }

    private fun startRecording() {
        if (isRecording) return
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
        addLog("录音已开始")

        vadDetector = VadDetector(sampleRate = SAMPLE_RATE).apply {
            setCallback(object : VadDetector.Callback {
                override fun onVadStart() {
                    resetTrace()
                    currentTraceId = generateTraceId()
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
                    channel?.pushStreamAudioData(data, 1, null)
                }
            }
        }.start()
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

    private fun playTtsAudio(data: ByteArray) {
        try {
            if (audioTrack == null || audioTrack?.state == AudioTrack.STATE_UNINITIALIZED) {
                val minBuf = AudioTrack.getMinBufferSize(
                    SAMPLE_RATE, AudioFormat.CHANNEL_OUT_MONO, AudioFormat.ENCODING_PCM_16BIT
                )
                audioTrack = AudioTrack.Builder()
                    .setAudioAttributes(
                        android.media.AudioAttributes.Builder()
                            .setUsage(android.media.AudioAttributes.USAGE_MEDIA)
                            .setContentType(android.media.AudioAttributes.CONTENT_TYPE_SPEECH)
                            .build()
                    )
                    .setAudioFormat(
                        AudioFormat.Builder()
                            .setSampleRate(SAMPLE_RATE)
                            .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                            .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                            .build()
                    )
                    .setBufferSizeInBytes(minBuf.coerceAtLeast(SAMPLE_RATE * 2))
                    .setTransferMode(AudioTrack.MODE_STREAM)
                    .build()
                audioTrack?.play()
            }
            audioTrack?.write(data, 0, data.size)
        } catch (e: Exception) {
            Log.e(TAG, "播放 TTS 异常", e)
        }
    }

    override fun onCleared() {
        super.onCleared()
        stop()
    }
}
