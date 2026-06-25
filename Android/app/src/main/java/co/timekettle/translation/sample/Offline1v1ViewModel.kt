package co.timekettle.translation.sample
import co.timekettle.translation.TmkTranslationException
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
import co.timekettle.translation.config.TmkTransChannelConfig
import co.timekettle.translation.core.AbstractChannelEngine
import co.timekettle.translation.enums.Scenario
import co.timekettle.translation.enums.TmkOfflineAudioChannelMode
import co.timekettle.translation.enums.TranslationMode
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
import co.timekettle.translation.utils.RingBuffer
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
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
    private var speakerCancelable: Cancelable? = null
    private var audioRecord: AudioRecord? = null
    private var audioTrack: AudioTrack? = null
    private var rightVadDetector: VadDetector? = null
    @Volatile private var isRecording = false
    @Volatile private var isPlaying = false
    @Volatile private var released = false
    @Volatile private var userCancelledDownload = false

    // 左右声道 TTS RingBuffer
    private val leftTtsBuffer = RingBuffer(BYTES_PER_20MS * 50)  // ~1秒缓冲
    private val rightTtsBuffer = RingBuffer(BYTES_PER_20MS * 50)

    private val _isModelReady = MutableStateFlow(false)
    val isModelReady: StateFlow<Boolean> = _isModelReady.asStateFlow()

    private val _isDownloading = MutableStateFlow(false)
    val isDownloading: StateFlow<Boolean> = _isDownloading.asStateFlow()

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
    private val _leftSpeakerGender = MutableStateFlow(SpeakerGender.FEMALE)
    val leftSpeakerGender: StateFlow<SpeakerGender> = _leftSpeakerGender.asStateFlow()
    private val _rightSpeakerGender = MutableStateFlow(SpeakerGender.MALE)
    val rightSpeakerGender: StateFlow<SpeakerGender> = _rightSpeakerGender.asStateFlow()
    private val _offlineAudioChannelMode = MutableStateFlow(TmkOfflineAudioChannelMode.STEREO)
    val offlineAudioChannelMode: StateFlow<TmkOfflineAudioChannelMode> = _offlineAudioChannelMode.asStateFlow()
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
            scenario = Scenario.ONE_TO_ONE,
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
                addLog("离线一对一通道已就绪，可以开始收听")
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
        addLog("开始下载 ${TranslationLanguages.displayName(_sourceLang.value)} ↔ ${TranslationLanguages.displayName(_targetLang.value)} 双向模型...")

        var lastLoggedPct = -1L
        TmkTranslationSDK.downloadOfflineModels(
            context = application,
            srcLang = _sourceLang.value,
            dstLang = _targetLang.value,
            scenario = Scenario.ONE_TO_ONE,
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
            addLog("离线一对一通道未就绪，尝试重新准备")
            initSDK()
            return
        }
        if (_isStarted.value) return
        startTtsPlaybackThread()
        if (!startDualChannelStreaming()) {
            stopTtsPlayback()
            return
        }
        _isStarted.value = true
        addLog("离线一对一已开始采集")
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
        addLog("创建离线 1v1 翻译通道...")

        TmkTranslationSDK.createTmkTranslationRoom(object : CreateRoomCallback {
            override fun onSuccess(room: TmkTranslationRoom) {
                if (released) { _isStarting.value = false; return }
                addLog("创建房间成功: ${room.roomId}")

                val modelRootDir = TmkTranslationSDK.defaultOfflineModelRootDirectory(application)

                val channelConfig = TmkTransChannelConfig.Builder()
                    .setRoom(room)
                    .setMode(TranslationMode.OFFLINE)
                    .setScenario(Scenario.ONE_TO_ONE)
                    // SDK 接口仍使用 source/target；Demo 一对一语义固定映射为 source=right、target=left。
                    .setSourceLang(_sourceLang.value)
                    .setTargetLang(_targetLang.value)
                    .setSpeakers(currentSpeakers())
                    .setSampleRate(SAMPLE_RATE)
                    .setChannelNum(2)
                    .setOfflineAudioChannelMode(_offlineAudioChannelMode.value)
                    .setModelRootDirectory(modelRootDir)
                    .build()

                addLog("left=${_targetLang.value} right=${_sourceLang.value} modelRootDirectory: $modelRootDir")

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
                            channel = ch
                            addLog("创建离线 1v1 Channel 成功")
                            _isStarting.value = false
                            _isChannelReady.value = true
                        }

                        override fun onError(errorId: Int, e: Exception) {
                            addLog("创建 Channel 失败: [$errorId] ${e.message}")
                            _isStarting.value = false
                            showConversationErrorPrompt(
                                OnlineConversationErrorPrompts.fromCode(
                                    errorId,
                                    e.message ?: "create offline one-to-one channel failed",
                                    mode = OnlineConversationErrorPrompts.RuntimeMode.OFFLINE,
                                )
                            )
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

    fun stopListening() {
        stopRecording()
        stopTtsPlayback()
        _isStarted.value = false
        addLog("离线一对一已停止采集")
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
        addLog("离线 1v1 翻译已停止")
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

    fun setOfflineAudioChannelMode(mode: TmkOfflineAudioChannelMode) {
        if (_offlineAudioChannelMode.value == mode) return
        _offlineAudioChannelMode.value = mode
        val modeName = if (mode == TmkOfflineAudioChannelMode.STEREO) "Stereo" else "Mono"
        when {
            _isStarting.value -> {
                addLog("离线一对一 TTS 输出模式已切换为 $modeName，当前正在启动，将在本次通道创建时生效")
            }
            _isStarted.value -> {
                addLog("离线一对一 TTS 输出模式已切换为 $modeName，正在重建离线通道...")
                stop()
                initSDK()
            }
            channel != null -> {
                addLog("离线一对一 TTS 输出模式已切换为 $modeName，正在重建离线通道...")
                stop()
                initSDK()
            }
            else -> {
                addLog("离线一对一 TTS 输出模式已切换为 $modeName，将在创建离线通道时生效")
            }
        }
    }

    fun updateSpeakers(leftGender: SpeakerGender, rightGender: SpeakerGender) {
        _leftSpeakerGender.value = leftGender
        _rightSpeakerGender.value = rightGender
        val currentChannel = channel
        if (currentChannel == null) {
            addLog("音色已设置为 L=${speakerLabel(leftGender)} R=${speakerLabel(rightGender)}，将在创建离线通道时生效")
            return
        }
        speakerCancelable?.cancel()
        val speakers = currentSpeakers()
        speakerCancelable = currentChannel.updateSpeaker(
            speakers,
            object : ActionCallback {
                override fun onSuccess(result: Result<Unit>) {
                    addLog("音色设置成功: L=${speakerLabel(leftGender)} R=${speakerLabel(rightGender)}，下一次 TTS 生效")
                }

                override fun onError(errorId: Int, e: Exception) {
                    addLog("音色设置失败: [$errorId] ${e.message}")
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

    private fun extractPcmChannel(data: ByteArray, channelCount: Int, channelIndex: Int): ByteArray {
        if (channelCount <= 1) return data
        val frameSize = channelCount * 2
        val frameCount = data.size / frameSize
        val output = ByteArray(frameCount * 2)
        for (index in 0 until frameCount) {
            val inOffset = index * frameSize + channelIndex * 2
            val outOffset = index * 2
            output[outOffset] = data[inOffset]
            output[outOffset + 1] = data[inOffset + 1]
        }
        return output
    }

    private fun appendTtsBuffer(ch: String, data: ByteArray, channelCount: Int) {
        when (ch) {
            // SDK 离线 1v1 已对外回调 stereo PCM；Demo 仍按左右缓冲播放，需取出对应声道。
            "left" -> leftTtsBuffer.write(extractPcmChannel(data, channelCount, 0))
            "right" -> rightTtsBuffer.write(extractPcmChannel(data, channelCount, 1))
            else -> {
                leftTtsBuffer.write(extractPcmChannel(data, channelCount, 0))
                rightTtsBuffer.write(extractPcmChannel(data, channelCount, if (channelCount > 1) 1 else 0))
            }
        }
    }

    private val translationListener = object : TmkTranslationListener {
        override fun onRecognized(fromEngine: AbstractChannelEngine?, r: co.timekettle.translation.model.Result<String>?, isFinal: Boolean) {
            Log.d(TAG, DemoTmkResultLogFormatter.makeLine("Offline1V1", "ASR", r, isFinal))
            val text = r?.data ?: ""
            val ch = normalizeChannel(r?.extraData?.get("channel"))
            val src = r?.srcCode?.takeIf { it.isNotEmpty() } ?: _sourceLang.value
            val dst = r?.dstCode?.takeIf { it.isNotEmpty() } ?: _targetLang.value
            DemoConversationEventAdapter.makeRecognizedEvent(r, isFinal, src, dst)?.let { bubbleAssembler.consume(it) }
            publishBubbles()
            if (!isFinal) return
            addLog("ASR [ch=$ch final=$isFinal]: $text")
        }

        override fun onTranslate(fromEngine: AbstractChannelEngine?, r: co.timekettle.translation.model.Result<String>?, isFinal: Boolean) {
            Log.d(TAG, DemoTmkResultLogFormatter.makeLine("Offline1V1", "MT", r, isFinal))
            val text = r?.data ?: ""
            val ch = normalizeChannel(r?.extraData?.get("channel"))
            val src = r?.srcCode?.takeIf { it.isNotEmpty() } ?: _sourceLang.value
            val dst = r?.dstCode?.takeIf { it.isNotEmpty() } ?: _targetLang.value
            DemoConversationEventAdapter.makeTranslatedEvent(r, isFinal, src, dst)?.let { bubbleAssembler.consume(it) }
            publishBubbles()
            if (!isFinal) return
            addLog("MT [ch=$ch final=$isFinal]: $text")
        }

        override fun onAudioDataReceive(fromEngine: AbstractChannelEngine?, r: co.timekettle.translation.model.Result<String>?, data: ByteArray, channelCount: Int) {
            val ch = normalizeChannel(r?.extraData?.get("channel"))
            appendTtsBuffer(ch, data, channelCount)
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
     * 双声道推流：左声道固定资产 PCM，右声道麦克风。
     */
    private fun startDualChannelStreaming(): Boolean {
        if (ContextCompat.checkSelfPermission(application, Manifest.permission.RECORD_AUDIO)
            != PackageManager.PERMISSION_GRANTED
        ) {
            addLog("没有录音权限")
            return false
        }
        if (isRecording) return true

        val bufferSize = AudioRecord.getMinBufferSize(
            SAMPLE_RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT
        )
        audioRecord = AudioRecord(
            MediaRecorder.AudioSource.MIC, SAMPLE_RATE,
            AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT, bufferSize
        )
        isRecording = true
        audioRecord?.startRecording()
        addLog("双声道推流已开始 (左:资产PCM, 右:麦克风)")

        rightVadDetector = VadDetector(sampleRate = SAMPLE_RATE).apply {
            setCallback(object : VadDetector.Callback {
                override fun onVadStart() {
                    addLog("VAD R → 开始说话")
                }
                override fun onVadEnd() {
                    addLog("VAD R → 停止说话")
                }
            }); init()
        }

        Thread {
            val samplesPer20ms = 320
            val bytesPerChannel = samplesPer20ms * 2
            val micBuf = ByteArray(bytesPerChannel)
            val pcmBuf = ByteArray(bytesPerChannel)
            val stereoBuf = ByteArray(bytesPerChannel * 2)
            val leftLoopBuffer = DemoLocalAudioLoopBuffer(readDemoPcmAsset("en_simple.pcm"))

            while (isRecording) {
                // 右声道麦克风数据
                var micOffset = 0
                while (micOffset < bytesPerChannel && isRecording) {
                    val read = audioRecord?.read(micBuf, micOffset, bytesPerChannel - micOffset) ?: -1
                    if (read > 0) micOffset += read
                }

                // 对齐 iOS Demo：左声道资产 PCM 播完后先推 3 秒静音，再从头循环。
                leftLoopBuffer.fillNextLoopChunk(pcmBuf)

                val leftBuf = pcmBuf
                val rightBuf = micBuf

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

    private fun stopRecording() {
        isRecording = false
        rightVadDetector?.release(); rightVadDetector = null
        try {
            audioRecord?.stop()
            audioRecord?.release()
        } catch (_: Exception) {}
        audioRecord = null
    }

    override fun onCleared() {
        super.onCleared()
        stop()
    }
}
