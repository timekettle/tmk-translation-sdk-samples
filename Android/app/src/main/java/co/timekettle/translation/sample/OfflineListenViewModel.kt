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
import co.timekettle.offlinesdk.vad.VadDetector
import co.timekettle.translation.config.TmkTransChannelConfig
import co.timekettle.translation.core.AbstractChannelEngine
import co.timekettle.translation.enums.Scenario
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
import co.timekettle.translation.model.TmkTranslationChannelStateSnapshot
import co.timekettle.translation.model.TmkTranslationRoom
import co.timekettle.translation.offlinemodel.TmkOfflineModelDownloadListener
import co.timekettle.translation.offlinemodel.TmkOfflineModelPackageInfo
import co.timekettle.translation.offlinemodel.TmkOfflineModelPackageState
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
    private var speakerCancelable: Cancelable? = null
    private var audioRecord: AudioRecord? = null
    private var audioTrack: AudioTrack? = null
    private var vadDetector: VadDetector? = null
    @Volatile private var isRecording = false
    @Volatile private var released = false
    @Volatile private var userCancelledDownload = false

    // 推流元数据（携带声道标识，供 SDK 音频路由使用）
    @Volatile private var pendingMetadata: ByteArray? = null

    private val _isModelReady = MutableStateFlow(false)
    val isModelReady: StateFlow<Boolean> = _isModelReady.asStateFlow()

    private val _isDownloading = MutableStateFlow(false)
    val isDownloading: StateFlow<Boolean> = _isDownloading.asStateFlow()

    /** 下载进度提示文本，如 "asr/zh (2/5) 63%" */
    private val _downloadProgress = MutableStateFlow("")
    val downloadProgress: StateFlow<String> = _downloadProgress.asStateFlow()

    private val _offlineModelPackages = MutableStateFlow<List<TmkOfflineModelPackageInfo>>(emptyList())
    val offlineModelPackages: StateFlow<List<TmkOfflineModelPackageInfo>> = _offlineModelPackages.asStateFlow()

    private val _isInitialized = MutableStateFlow(false)
    val isInitialized: StateFlow<Boolean> = _isInitialized.asStateFlow()
    private val _initErrorMessage = MutableStateFlow<String?>(null)
    val initErrorMessage: StateFlow<String?> = _initErrorMessage.asStateFlow()

    private val _isStarted = MutableStateFlow(false)
    val isStarted: StateFlow<Boolean> = _isStarted.asStateFlow()

    private val _isChannelReady = MutableStateFlow(false)
    val isChannelReady: StateFlow<Boolean> = _isChannelReady.asStateFlow()

    private val _isStarting = MutableStateFlow(false)
    val isStarting: StateFlow<Boolean> = _isStarting.asStateFlow()

    private val _conversationErrorPrompt = MutableStateFlow<OnlineConversationErrorPrompt?>(null)
    val conversationErrorPrompt: StateFlow<OnlineConversationErrorPrompt?> = _conversationErrorPrompt.asStateFlow()

    private val _isCheckingOfflineSupport = MutableStateFlow(false)
    val isCheckingOfflineSupport: StateFlow<Boolean> = _isCheckingOfflineSupport.asStateFlow()

    private val _isOfflineSupported = MutableStateFlow(false)
    val isOfflineSupported: StateFlow<Boolean> = _isOfflineSupported.asStateFlow()

    private val _offlineSupportChecked = MutableStateFlow(false)
    val offlineSupportChecked: StateFlow<Boolean> = _offlineSupportChecked.asStateFlow()

    private val _logMessages = MutableStateFlow<List<String>>(emptyList())
    val logMessages: StateFlow<List<String>> = _logMessages.asStateFlow()

    private val bubbleAssembler = DemoConversationBubbleAssembler()
    private val _bubbles = MutableStateFlow<List<DemoConversationBubbleSnapshot>>(emptyList())
    val bubbles: StateFlow<List<DemoConversationBubbleSnapshot>> = _bubbles.asStateFlow()

    private val _sourceLang = MutableStateFlow("zh-CN")
    val sourceLang: StateFlow<String> = _sourceLang.asStateFlow()
    private val _targetLang = MutableStateFlow("en-US")
    val targetLang: StateFlow<String> = _targetLang.asStateFlow()
    private val _speakerGender = MutableStateFlow(SpeakerGender.FEMALE)
    val speakerGender: StateFlow<SpeakerGender> = _speakerGender.asStateFlow()
    private var hasLockedLanguages = false

    fun setLanguagesIfNeeded(sourceLang: String, targetLang: String) {
        if (hasLockedLanguages) return
        _sourceLang.value = sourceLang
        _targetLang.value = targetLang
        hasLockedLanguages = true
        if (_offlineSupportChecked.value && _isOfflineSupported.value) {
            refreshModelReady()
        }
    }

    private fun refreshModelReady() {
        if (!_isOfflineSupported.value) {
            _offlineModelPackages.value = emptyList()
            _isModelReady.value = false
            return
        }
        val packages = TmkTranslationSDK.getOfflineModelPackageInfos(
            context = application,
            srcLang = _sourceLang.value,
            dstLang = _targetLang.value,
            scenario = Scenario.LISTEN,
            needMt = true,
            needTts = true,
        )
        _offlineModelPackages.value = packages
        _isModelReady.value = packages.isNotEmpty() && packages.all { it.state == TmkOfflineModelPackageState.READY }
    }

    private fun addLog(msg: String) {
        Log.d(TAG, msg)
        _logMessages.value = listOf(msg) + _logMessages.value.take(99)
    }

    private fun publishBubbles() { _bubbles.value = bubbleAssembler.snapshotWithSegments() }

    private fun showConversationErrorPrompt(prompt: OnlineConversationErrorPrompt?) {
        if (prompt == null || _conversationErrorPrompt.value?.id == prompt.id) return
        _conversationErrorPrompt.value = prompt
    }

    private fun applySdkChannelSnapshot(snapshot: TmkTranslationChannelStateSnapshot) {
        when (snapshot.state) {
            TmkTranslationChannelState.STARTING -> {
                _isStarting.value = true
                _isChannelReady.value = false
            }
            TmkTranslationChannelState.RUNNING -> {
                _isStarting.value = false
                _isChannelReady.value = true
                addLog("离线通道已就绪，可以开始收听")
            }
            TmkTranslationChannelState.STOPPING -> {
                _isChannelReady.value = false
                if (_isStarted.value) stopListening()
            }
            TmkTranslationChannelState.STOPPED -> {
                _isStarting.value = false
                _isChannelReady.value = false
                if (_isStarted.value) stopListening()
            }
            TmkTranslationChannelState.FAILED -> {
                _isStarting.value = false
                _isChannelReady.value = false
                if (_isStarted.value) stopListening()
                addLog("通道异常: ${snapshot.message}")
                showConversationErrorPrompt(
                    OnlineConversationErrorPrompts.fromSnapshot(
                        snapshot,
                        OnlineConversationErrorPrompts.RuntimeMode.OFFLINE,
                    )
                )
            }
            TmkTranslationChannelState.IDLE -> {
                _isStarting.value = false
                _isChannelReady.value = false
            }
            TmkTranslationChannelState.RECONNECTING,
            TmkTranslationChannelState.DEGRADED -> Unit
        }
    }

    private fun buildMetadataBytes(channel: Int): ByteArray {
        val now = java.util.Calendar.getInstance()
        val hour = now.get(java.util.Calendar.HOUR_OF_DAY)
        val minute = now.get(java.util.Calendar.MINUTE)
        val second = now.get(java.util.Calendar.SECOND)
        return byteArrayOf(channel.toByte(), hour.toByte(), minute.toByte(), second.toByte())
    }

    private fun resetMetadata() {
        pendingMetadata = null
    }

    fun downloadModels() {
        if (_isDownloading.value) return
        released = false
        userCancelledDownload = false
        if (!_offlineSupportChecked.value) {
            verifyAuthThenRefreshOfflineState(autoStartIfReady = false, autoDownloadIfNeeded = true)
            return
        }
        if (!_isOfflineSupported.value) {
            applyOfflineUnsupportedState()
            return
        }
        _isDownloading.value = true
        _downloadProgress.value = "准备下载..."
        addLog("开始下载 ${TranslationLanguages.displayName(_sourceLang.value)} → ${TranslationLanguages.displayName(_targetLang.value)} 模型...")

        var lastLoggedPct = -1L
        TmkTranslationSDK.downloadOfflineModels(
            context = application,
            srcLang = _sourceLang.value,
            dstLang = _targetLang.value,
            scenario = Scenario.LISTEN,
            needMt = true,
            needTts = true,
            listener = object : TmkOfflineModelDownloadListener {
                override fun onOfflineModelDownloadProgress(
                    fileName: String,
                    index: Int,
                    total: Int,
                    downloaded: Long,
                    fileTotal: Long,
                ) {
                    if (userCancelledDownload) return
                    val pct = if (fileTotal > 0) (downloaded * 100 / fileTotal) else 0
                    _downloadProgress.value = "($index/$total) $fileName ${pct}%"
                    if (pct >= lastLoggedPct + 5) {
                        lastLoggedPct = pct
                        addLog("[$fileName] $pct%")
                    }
                }

                override fun onOfflineModelUnzipProgress(fileName: String, progress: Double) {
                    if (userCancelledDownload) return
                    _downloadProgress.value = "$fileName 解压中 ${(progress * 100).toInt()}%"
                }

                override fun onOfflineModelReady() {
                    if (released || userCancelledDownload) return
                    addLog("模型下载完成")
                    _downloadProgress.value = "下载完成"
                    _isDownloading.value = false
                    refreshModelReady()
                    if (_isModelReady.value) {
                        prepareChannelIfNeeded()
                    }
                }

                override fun onOfflineModelPackageInfosChanged(packages: List<TmkOfflineModelPackageInfo>) {
                    if (released || userCancelledDownload) return
                    _offlineModelPackages.value = packages
                    _isModelReady.value = packages.isNotEmpty() && packages.all { it.state == TmkOfflineModelPackageState.READY }
                }

                override fun onOfflineModelEvent(name: String, args: Any?) {
                    if (released) return
                    if (name == "offline_model_cancelled") {
                        userCancelledDownload = true
                        _downloadProgress.value = "下载已取消"
                        _isDownloading.value = false
                        refreshModelReady()
                    } else if (name == "offline_model_update_required") {
                        _downloadProgress.value = "模型需要更新"
                        refreshModelReady()
                    }
                }

                override fun onOfflineModelError(code: Int, message: String) {
                    if (released || userCancelledDownload) return
                    addLog("下载失败: [$code] $message")
                    showConversationErrorPrompt(
                        OnlineConversationErrorPrompts.fromCode(
                            code,
                            message,
                            mode = OnlineConversationErrorPrompts.RuntimeMode.OFFLINE,
                        )
                    )
                    _downloadProgress.value = "下载失败"
                    _isDownloading.value = false
                    refreshModelReady()
                }
            },
        )
    }

    fun cancelDownloadModels() {
        if (!_isDownloading.value) return
        userCancelledDownload = true
        TmkTranslationSDK.cancelOfflineModelDownload()
        _isDownloading.value = false
        _downloadProgress.value = "下载已取消"
        refreshModelReady()
        addLog("已取消离线模型下载")
    }

    fun initSDK() {
        released = false
        verifyAuthThenRefreshOfflineState(autoStartIfReady = true)
    }

    private fun ensureSdkInitialized(): Boolean {
        return try {
            if (!_isInitialized.value) {
                TmkTranslationSDK.sdkInit(application, SampleSdkConfig.globalConfig(application))
                _isInitialized.value = true
                _initErrorMessage.value = null
                addLog("SDK 初始化完成")
            }
            true
        } catch (e: Exception) {
            addLog("SDK 初始化异常: ${e.message}")
            _initErrorMessage.value = SampleSdkConfig.buildInitErrorMessage(e)
            Log.e(TAG, "initSDK failed", e)
            false
        }
    }

    fun dismissInitError() {
        _initErrorMessage.value = null
    }

    private fun verifyAuthThenRefreshOfflineState(
        autoStartIfReady: Boolean,
        autoDownloadIfNeeded: Boolean = false,
    ) {
        if (!ensureSdkInitialized()) return
        if (_isCheckingOfflineSupport.value) return
        _isCheckingOfflineSupport.value = true
        addLog("开始鉴权并检查离线能力...")
        try {
            TmkTranslationSDK.verifyAuth(object : AuthCallback {
                override fun onSuccess() {
                    if (released) {
                        _isCheckingOfflineSupport.value = false
                        return
                    }
                    _offlineSupportChecked.value = true
                    _isOfflineSupported.value = TmkTranslationSDK.isOfflineTranslationSupported()
                    _isCheckingOfflineSupport.value = false
                    if (!_isOfflineSupported.value) {
                        applyOfflineUnsupportedState()
                        return
                    }
                    addLog("鉴权成功，当前账号支持离线翻译")
                    refreshModelReady()
                    if (_isModelReady.value) {
                        if (autoStartIfReady) prepareChannelIfNeeded()
                    } else {
                        addLog("当前模型资源不完整，需要先下载离线资源")
                        if (autoDownloadIfNeeded) downloadModels()
                    }
                }

                override fun onError(errorId: Int, e: Exception) {
                    _offlineSupportChecked.value = false
                    _isOfflineSupported.value = false
                    _isCheckingOfflineSupport.value = false
                    _isModelReady.value = false
                    _offlineModelPackages.value = emptyList()
                    addLog("鉴权失败: [$errorId] ${e.message}")
                    showConversationErrorPrompt(
                        OnlineConversationErrorPrompts.fromCode(
                            errorId,
                            e.message ?: "offline auth failed",
                            mode = OnlineConversationErrorPrompts.RuntimeMode.OFFLINE,
                        )
                    )
                }
            })
        } catch (e: Exception) {
            _offlineSupportChecked.value = false
            _isOfflineSupported.value = false
            _isCheckingOfflineSupport.value = false
            _isModelReady.value = false
            _offlineModelPackages.value = emptyList()
            addLog("鉴权异常: ${e.message}")
            Log.e(TAG, "verifyAuth failed", e)
        }
    }

    private fun applyOfflineUnsupportedState() {
        TmkTranslationSDK.releaseChannel()
        channel = null
        _isChannelReady.value = false
        _isStarting.value = false
        _isStarted.value = false
        _isDownloading.value = false
        _downloadProgress.value = ""
        _offlineModelPackages.value = emptyList()
        _isModelReady.value = false
        addLog("当前账号未开通离线翻译能力")
        showConversationErrorPrompt(
            OnlineConversationErrorPrompts.fromCode(
                TmkTranslationException.ErrorCodes.OFFLINE_MODEL_NOT_READY,
                "当前账号未开通离线翻译能力",
                mode = OnlineConversationErrorPrompts.RuntimeMode.OFFLINE,
            )
        )
    }

    fun start() {
        if (!_isInitialized.value || channel == null || !_isChannelReady.value) {
            addLog("离线通道未就绪，尝试重新准备")
            initSDK()
            return
        }
        if (_isStarted.value) return
        if (!startRecording()) return
        _isStarted.value = true
        addLog("离线收听已开始采集")
    }

    private fun prepareChannelIfNeeded() {
        if (channel != null || _isStarting.value) return
        if (!_isOfflineSupported.value) {
            applyOfflineUnsupportedState()
            return
        }
        if (OfflineDemoModelReadinessPolicy.shouldRefreshBeforePreparingChannel(_isModelReady.value)) {
            refreshModelReady()
        }
        if (!_isModelReady.value) {
            addLog("当前模型资源不完整，需要先下载离线资源")
            return
        }
        released = false
        _isStarting.value = true
        doStart()
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
                        val modelRootDir = TmkTranslationSDK.defaultOfflineModelRootDirectory(application)

                        val channelConfig = TmkTransChannelConfig.Builder()
                            .setRoom(room)
                            .setMode(TranslationMode.OFFLINE)
                            .setScenario(Scenario.LISTEN)
                            .setTransModeType(TransModeType.LISTEN)
                            .setSourceLang(_sourceLang.value)
                            .setTargetLang(_targetLang.value)
                            .setSpeakers(listOf(TmkSpeaker(SpeakerChannel.LEFT, _speakerGender.value)))
                            .setSampleRate(SAMPLE_RATE)
                            .setChannelNum(1)
                            .setModelRootDirectory(modelRootDir)
                            .build()

                        addLog("src=${_sourceLang.value} tgt=${_targetLang.value} modelRootDirectory: $modelRootDir")

                        TmkTranslationSDK.createTranslationChannel(
                            application,
                            channelConfig,
                            translationListener,
                            object : CreateChannelCallback {
                                override fun onSuccess(ch: TmkTranslationChannel) {
                                    if (released) {
                                        TmkTranslationSDK.releaseChannel()
                                        _isStarting.value = false
                                        return
                                    }
                                    try {
                                        channel = ch
                                        addLog("创建离线 Channel 成功")
                                        _isStarting.value = false
                                        _isChannelReady.value = true
                                    } catch (e: Exception) {
                                        addLog("启动离线 Channel 异常: ${e.message}")
                                        Log.e(TAG, "start channel failed", e)
                                        channel = null
                                        _isChannelReady.value = false
                                        _isStarting.value = false
                                    }
                                }

                                override fun onError(errorId: Int, e: Exception) {
                                    addLog("创建 Channel 失败: [$errorId] ${e.message}")
                                    _isStarting.value = false
                                    showConversationErrorPrompt(
                                        OnlineConversationErrorPrompts.fromCode(
                                            errorId,
                                            e.message ?: "create offline channel failed",
                                            mode = OnlineConversationErrorPrompts.RuntimeMode.OFFLINE,
                                        )
                                    )
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

    fun stopListening() {
        stopRecording()
        try {
            audioTrack?.pause()
            audioTrack?.flush()
            audioTrack?.stop()
            audioTrack?.release()
        } catch (_: Exception) {}
        audioTrack = null
        _isStarted.value = false
        addLog("离线收听已停止采集")
    }

    fun stop() {
        released = true
        if (_isDownloading.value) {
            userCancelledDownload = true
            TmkTranslationSDK.cancelOfflineModelDownload()
            _isDownloading.value = false
            _downloadProgress.value = ""
        }
        speakerCancelable?.cancel()
        speakerCancelable = null
        stopListening()
        TmkTranslationSDK.releaseChannel()
        channel = null
        _isChannelReady.value = false
        _isStarting.value = false
        _isStarted.value = false
        _conversationErrorPrompt.value = null
        addLog("离线翻译已停止")
    }

    fun recreateChannelAfterRuntimeFailure() {
        _conversationErrorPrompt.value = null
        stop()
        released = false
        initSDK()
    }

    fun dismissConversationErrorPrompt() {
        _conversationErrorPrompt.value = null
    }

    fun updateSpeaker(gender: SpeakerGender) {
        _speakerGender.value = gender
        val currentChannel = channel
        if (currentChannel == null) {
            addLog("音色已设置为${speakerLabel(gender)}，将在创建离线通道时生效")
            return
        }
        speakerCancelable?.cancel()
        speakerCancelable = currentChannel.updateSpeaker(
            listOf(TmkSpeaker(SpeakerChannel.LEFT, gender)),
            object : ActionCallback {
                override fun onSuccess(result: Result<Unit>) {
                    addLog("音色设置成功: ${speakerLabel(gender)}，下一次 TTS 生效")
                }

                override fun onError(errorId: Int, e: Exception) {
                    addLog("音色设置失败: [$errorId] ${e.message}")
                }
            }
        )
    }

    private fun speakerLabel(gender: SpeakerGender): String = when (gender) {
        SpeakerGender.MALE -> "男声"
        SpeakerGender.FEMALE -> "女声"
    }

    private val translationListener = object : TmkTranslationListener {
        override fun onRecognized(fromEngine: AbstractChannelEngine?, r: co.timekettle.translation.model.Result<String>?, isFinal: Boolean) {
            Log.d(TAG, DemoTmkResultLogFormatter.makeLine("OfflineListen", "ASR", r, isFinal))
            val text = r?.data ?: ""
            val src = r?.srcCode?.takeIf { it.isNotEmpty() } ?: _sourceLang.value
            val dst = r?.dstCode?.takeIf { it.isNotEmpty() } ?: _targetLang.value
            DemoConversationEventAdapter.makeRecognizedEvent(r, isFinal, src, dst)?.let { bubbleAssembler.consume(it) }
            publishBubbles()
            addLog("ASR [final=$isFinal]: $text")
        }

        override fun onTranslate(fromEngine: AbstractChannelEngine?, r: co.timekettle.translation.model.Result<String>?, isFinal: Boolean) {
            Log.d(TAG, DemoTmkResultLogFormatter.makeLine("OfflineListen", "MT", r, isFinal))
            val text = r?.data ?: ""
            val src = r?.srcCode?.takeIf { it.isNotEmpty() } ?: _sourceLang.value
            val dst = r?.dstCode?.takeIf { it.isNotEmpty() } ?: _targetLang.value
            DemoConversationEventAdapter.makeTranslatedEvent(r, isFinal, src, dst)?.let { bubbleAssembler.consume(it) }
            publishBubbles()
            addLog("MT [final=$isFinal]: $text")
        }

        override fun onAudioDataReceive(fromEngine: AbstractChannelEngine?, r: co.timekettle.translation.model.Result<String>?, data: ByteArray, channelCount: Int) {
            playTtsAudio(data)
        }

        override fun onError(code: Int, msg: String) {
            addLog("Error [$code]: $msg")
            showConversationErrorPrompt(
                OnlineConversationErrorPrompts.fromCode(
                    code,
                    msg,
                    mode = OnlineConversationErrorPrompts.RuntimeMode.OFFLINE,
                )
            )
        }
        override fun onEvent(eventName: String, args: Any?) { addLog("Event: $eventName") }
        override fun onStateChanged(fromEngine: AbstractChannelEngine?, snapshot: TmkTranslationChannelStateSnapshot) {
            addLog("状态变化: ${snapshot.state.rawValue}/${snapshot.reason.rawValue} ${snapshot.message}")
            applySdkChannelSnapshot(snapshot)
        }
    }

    private fun startRecording(): Boolean {
        if (isRecording) return true
        if (ContextCompat.checkSelfPermission(application, Manifest.permission.RECORD_AUDIO)
            != PackageManager.PERMISSION_GRANTED
        ) {
            addLog("没有录音权限")
            return false
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
                    resetMetadata()
                    // 生成推流元数据,SDK 依据其首字节区分声道,属正常音频路由所需。
                    pendingMetadata = buildMetadataBytes(channel = 1)
                    addLog("VAD → 开始说话")
                }
                override fun onVadEnd() {
                    addLog("VAD → 停止说话")
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
                    val metadata = pendingMetadata
                    pendingMetadata = null
                    channel?.pushStreamAudioData(data, 1, metadata)
                }
            }
        }.start()
        return true
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
