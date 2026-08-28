package co.timekettle.translation.sample

import android.Manifest
import android.app.Application
import android.content.pm.PackageManager
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.core.content.ContextCompat
import androidx.lifecycle.ViewModel
import co.timekettle.offlinesdk.vad.VadDetector
import co.timekettle.translation.config.TmkCreateChannelOptions
import co.timekettle.translation.config.TmkTransChannelConfig
import co.timekettle.translation.config.TmkTranslationRoomConfig
import co.timekettle.translation.Cancelable
import co.timekettle.translation.TmkTranslationChannel
import co.timekettle.translation.TmkTranslationSDK
import co.timekettle.translation.core.AbstractChannelEngine
import co.timekettle.translation.enums.Scenario
import co.timekettle.translation.enums.TmkSensitiveWordRedactionOption
import co.timekettle.translation.enums.TranslationMode
import co.timekettle.sdk.common.enums.TransModeType
import co.timekettle.translation.listener.AuthCallback
import co.timekettle.translation.listener.CreateChannelCallback
import co.timekettle.translation.listener.CreateRoomCallback
import co.timekettle.translation.listener.TmkTranslationListener
import co.timekettle.translation.model.Result
import co.timekettle.sdk.common.models.SpeakerChannel
import co.timekettle.sdk.common.models.TmkSpeaker
import co.timekettle.translation.model.TmkTranslationChannelStateSnapshot
import co.timekettle.translation.model.TmkTranslationRoom
import co.timekettle.translation.offlinemodel.TmkOfflineModelDownloadListener
import co.timekettle.translation.offlinemodel.TmkOfflineModelPackageInfo
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.util.Calendar
import java.util.Locale
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import javax.inject.Inject

/**
 * ConcurrentOneToOne 的唯一场景协调器。
 * 两路 Runtime 只拥有各自 Channel；本类统一拥有麦克风、VAD、Mapper 与 TTS Player。
 */
@HiltViewModel
class ConcurrentOneToOneViewModel @Inject constructor(
    private val application: Application,
) : ViewModel() {
    enum class TtsSource(val title: String) { ONLINE("在线"), OFFLINE("离线") }

    data class UiState(
        val onlineStatus: String = "准备中",
        val offlineStatus: String = "准备中",
        val captureStatus: String = "未开始",
        val modelStatus: String = "校验中",
        val modelTotalProgressText: String = "",
        val totalDownloadProgress: Float = 0f,
        val isModelDownloading: Boolean = false,
        val needsModelDownload: Boolean = false,
        val onlineCanRetry: Boolean = false,
        val offlineCanRetry: Boolean = false,
        val canStart: Boolean = false,
        val isRunning: Boolean = false,
        val ttsSource: TtsSource = TtsSource.ONLINE,
        val playbackMode: OneToOnePlaybackMode = OneToOnePlaybackMode.LEFT,
        val rows: List<ConcurrentConversationMapper.Row> = emptyList(),
    )

    companion object {
        private const val SAMPLE_RATE = OneToOneDemoDefaults.sampleRate
        private const val CHANNEL_COUNT = OneToOneDemoDefaults.channelCount
        private const val BYTES_PER_20_MS = 640
        private const val TAG = "Concurrent1v1"
    }

    private val mapper = ConcurrentConversationMapper()
    // 两路 Runtime 各持一个 TTS 封装类(在线/离线路由解析不同);TTS 来源(播在线还是离线)由本类守卫决定。
    private val onlineTtsCoordinator = DemoTtsPlaybackCoordinator(
        tag = "Concurrent1v1-Online",
        scene = DemoTtsScene.ONE_TO_ONE,
        runtime = DemoTtsRuntime.ONLINE,
        sampleRate = SAMPLE_RATE,
    )
    private val offlineTtsCoordinator = DemoTtsPlaybackCoordinator(
        tag = "Concurrent1v1-Offline",
        scene = DemoTtsScene.ONE_TO_ONE,
        runtime = DemoTtsRuntime.OFFLINE,
        sampleRate = SAMPLE_RATE,
    )
    private val _state = MutableStateFlow(UiState())
    val state: StateFlow<UiState> = _state.asStateFlow()

    // 一对一场景按实际声道保存语言：左路为本机/目标语言，右路为对方/源语言。
    private var leftLang = "en-US"
    private var rightLang = "zh-CN"
    // 创建回调在主线程、采集循环在后台线程；第二路可能在开始采集后才就绪，必须保证引用可见。
    @Volatile private var onlineChannel: TmkTranslationChannel? = null
    @Volatile private var offlineChannel: TmkTranslationChannel? = null
    /** 两路 Listener 独立持有，避免一侧重试/释放时误替换另一侧回调。 */
    private var onlineListener: TmkTranslationListener? = null
    private var offlineListener: TmkTranslationListener? = null
    private var onlineRoomOperation: Cancelable? = null
    private var onlineChannelOperation: Cancelable? = null
    private var offlineChannelOperation: Cancelable? = null
    private var audioRecord: AudioRecord? = null
    private var rightVad: VadDetector? = null
    private var recordingThread: Thread? = null
    private val audioCaptureLock = Any()
    @Volatile private var isRecording = false
    @Volatile private var released = false
    @Volatile private var pendingRightMetadata: ByteArray? = null
    private var prepared = false
    /** 每个 Runtime 独立的回调代次；重试/释放后丢弃旧 Channel 的迟到回调。 */
    private val onlineGeneration = AtomicLong(0)
    private val offlineGeneration = AtomicLong(0)
    private val stateLock = Any()
    /** TTS 来源/左右路切换与入队串行化，避免切换瞬间把旧 Runtime/旧声道帧重新入队。 */
    private val ttsSelectionLock = Any()
    private val mainHandler = Handler(Looper.getMainLooper())
    private val rowsPublishPending = AtomicBoolean(false)
    private val onlineFirstResultLogged = AtomicBoolean(false)
    private val offlineFirstResultLogged = AtomicBoolean(false)
    private val rowsPublisher = Runnable {
        rowsPublishPending.set(false)
        val snapshot = synchronized(mapper) { mapper.rows() }
        publish { it.copy(rows = snapshot) }
    }

    fun prepare(leftLanguage: String, rightLanguage: String) {
        if (prepared && leftLang == leftLanguage && rightLang == rightLanguage) return
        if (prepared && (leftLang != leftLanguage || rightLang != rightLanguage)) {
            cancelRuntimeOperations()
            onlineChannel?.destroy()
            offlineChannel?.destroy()
            onlineChannel = null
            offlineChannel = null
            onlineListener = null
            offlineListener = null
            onlineTtsCoordinator.clear()
            offlineTtsCoordinator.clear()
            mainHandler.removeCallbacks(rowsPublisher)
            rowsPublishPending.set(false)
        }
        onlineGeneration.incrementAndGet()
        offlineGeneration.incrementAndGet()
        onlineFirstResultLogged.set(false)
        offlineFirstResultLogged.set(false)
        val onlinePrepareGeneration = onlineGeneration.get()
        val offlinePrepareGeneration = offlineGeneration.get()
        leftLang = leftLanguage
        rightLang = rightLanguage
        released = false
        prepared = true
        try {
            TmkTranslationSDK.sdkInit(application, SampleSdkConfig.globalConfig(application))
        } catch (error: Exception) {
            prepared = false
            publish { it.copy(onlineStatus = "SDK 初始化失败：${error.message}", offlineStatus = "SDK 初始化失败") }
            return
        }
        publish {
            it.copy(
                onlineStatus = "鉴权中",
                offlineStatus = "鉴权中",
                modelStatus = "校验中",
                modelTotalProgressText = "",
                totalDownloadProgress = 0f,
                isModelDownloading = false,
                needsModelDownload = false,
                onlineCanRetry = false,
                offlineCanRetry = false,
            )
        }
        TmkTranslationSDK.verifyAuth(object : AuthCallback {
            override fun onSuccess() {
                if (!isCurrent(ConcurrentConversationMapper.Runtime.ONLINE, onlinePrepareGeneration) &&
                    !isCurrent(ConcurrentConversationMapper.Runtime.OFFLINE, offlinePrepareGeneration)
                ) return
                prepareOnline(onlinePrepareGeneration)
                prepareOffline(offlinePrepareGeneration)
            }

            override fun onError(errorId: Int, e: Exception) {
                if (!isCurrent(ConcurrentConversationMapper.Runtime.ONLINE, onlinePrepareGeneration) &&
                    !isCurrent(ConcurrentConversationMapper.Runtime.OFFLINE, offlinePrepareGeneration)
                ) return
                publish { state ->
                    state.copy(
                        onlineStatus = if (isCurrent(ConcurrentConversationMapper.Runtime.ONLINE, onlinePrepareGeneration)) "鉴权失败：${e.message}" else state.onlineStatus,
                        offlineStatus = if (isCurrent(ConcurrentConversationMapper.Runtime.OFFLINE, offlinePrepareGeneration)) "鉴权失败：${e.message}" else state.offlineStatus,
                        modelStatus = if (isCurrent(ConcurrentConversationMapper.Runtime.OFFLINE, offlinePrepareGeneration)) "不可用" else state.modelStatus,
                        onlineCanRetry = isCurrent(ConcurrentConversationMapper.Runtime.ONLINE, onlinePrepareGeneration) || state.onlineCanRetry,
                        offlineCanRetry = isCurrent(ConcurrentConversationMapper.Runtime.OFFLINE, offlinePrepareGeneration) || state.offlineCanRetry,
                    )
                }
            }
        })
    }

    fun start() {
        if (state.value.isRunning) return
        if (onlineChannel == null && offlineChannel == null) return
        if (ContextCompat.checkSelfPermission(application, Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            publish { it.copy(captureStatus = "麦克风权限未授权") }
            return
        }
        startAudioCapture()
    }

    fun stop() {
        stopAudioCapture()
    }

    fun retryOnline() {
        if (released || !state.value.onlineCanRetry) return
        val generation = onlineGeneration.incrementAndGet()
        onlineRoomOperation?.cancel()
        onlineRoomOperation = null
        onlineChannelOperation?.cancel()
        onlineChannelOperation = null
        onlineChannel?.destroy()
        onlineChannel = null
        onlineListener = null
        onlineFirstResultLogged.set(false)
        publish { it.copy(onlineStatus = "重试中", onlineCanRetry = false, canStart = offlineChannel != null) }
        prepareOnline(generation)
    }

    fun retryOffline() {
        if (released || !state.value.offlineCanRetry) return
        val generation = offlineGeneration.incrementAndGet()
        offlineChannelOperation?.cancel()
        offlineChannelOperation = null
        offlineChannel?.destroy()
        offlineChannel = null
        offlineListener = null
        offlineFirstResultLogged.set(false)
        publish { it.copy(offlineStatus = "重试中", offlineCanRetry = false, canStart = onlineChannel != null) }
        prepareOffline(generation)
    }

    fun downloadOfflineModels() {
        if (released || state.value.isModelDownloading) return
        val generation = offlineGeneration.get()
        publish {
            it.copy(
                modelStatus = "下载中",
                modelTotalProgressText = "总进度：0%",
                totalDownloadProgress = 0f,
                isModelDownloading = true,
                needsModelDownload = true,
                offlineCanRetry = false,
            )
        }
        TmkTranslationSDK.downloadOfflineModels(
            context = application,
            srcLang = rightLang,
            dstLang = leftLang,
            scenario = Scenario.ONE_TO_ONE,
            needMt = true,
            needTts = true,
            listener = object : TmkOfflineModelDownloadListener {
                override fun onOfflineModelDownloadProgress(fileName: String, index: Int, total: Int, downloaded: Long, fileTotal: Long) {
                    if (!isCurrent(ConcurrentConversationMapper.Runtime.OFFLINE, generation)) return
                    val percent = if (fileTotal > 0) downloaded * 100 / fileTotal else 0
                    publish { it.copy(modelStatus = "下载中 ($index/$total) $percent%", isModelDownloading = true, offlineCanRetry = false) }
                }

                override fun onOfflineModelUnzipProgress(fileName: String, progress: Double) {
                    if (!isCurrent(ConcurrentConversationMapper.Runtime.OFFLINE, generation)) return
                    publish { it.copy(modelStatus = "解压中 ${(progress * 100).toInt()}%") }
                }

                override fun onOfflineModelTotalProgress(downloadedBytesAll: Long, totalBytesAll: Long) {
                    if (!isCurrent(ConcurrentConversationMapper.Runtime.OFFLINE, generation)) return
                    val progress = if (totalBytesAll > 0L) {
                        (downloadedBytesAll.toFloat() / totalBytesAll.toFloat()).coerceIn(0f, 1f)
                    } else {
                        0f
                    }
                    val percent = if (totalBytesAll > 0L) "${(progress * 100).toInt()}%" else "计算中"
                    val totalText = if (totalBytesAll > 0L) formatBytes(totalBytesAll) else "未知"
                    publish {
                        it.copy(
                            totalDownloadProgress = progress,
                            modelTotalProgressText = "总进度：$percent（${formatBytes(downloadedBytesAll)} / $totalText）",
                            isModelDownloading = true,
                            offlineCanRetry = false,
                        )
                    }
                }
                override fun onOfflineModelPackageInfosChanged(packages: List<TmkOfflineModelPackageInfo>) = Unit
                override fun onOfflineModelEvent(name: String, args: Any?) = Unit

                override fun onOfflineModelReady() {
                    if (!isCurrent(ConcurrentConversationMapper.Runtime.OFFLINE, generation)) return
                    publish {
                        it.copy(
                            modelStatus = "模型已就绪",
                            modelTotalProgressText = "总进度：100%",
                            totalDownloadProgress = 1f,
                            isModelDownloading = false,
                            needsModelDownload = false,
                            offlineCanRetry = false,
                            offlineStatus = "准备中",
                        )
                    }
                    prepareOffline(generation)
                }

                override fun onOfflineModelError(code: Int, message: String) {
                    if (!isCurrent(ConcurrentConversationMapper.Runtime.OFFLINE, generation)) return
                    publish {
                        it.copy(
                            modelStatus = "下载失败：$message",
                            modelTotalProgressText = "总进度：下载失败",
                            isModelDownloading = false,
                            needsModelDownload = true,
                            offlineCanRetry = false,
                            offlineStatus = "模型不可用",
                        )
                    }
                }
            },
        )
    }

    fun selectTtsSource(source: TtsSource) {
        synchronized(ttsSelectionLock) {
            applyTtsSettingsLocked(source, state.value.playbackMode)
        }
    }

    fun selectPlaybackMode(mode: OneToOnePlaybackMode) {
        synchronized(ttsSelectionLock) {
            applyTtsSettingsLocked(state.value.ttsSource, mode)
        }
    }

    fun applyTtsSettings(source: TtsSource, mode: OneToOnePlaybackMode) {
        synchronized(ttsSelectionLock) {
            applyTtsSettingsLocked(source, mode)
        }
    }

    private fun applyTtsSettingsLocked(source: TtsSource, mode: OneToOnePlaybackMode) {
        publish { it.copy(ttsSource = source, playbackMode = mode) }
        // 设置提交时终止当前帧和待播队列，避免旧 Runtime/旧声道在新组合生效后继续出声。
        onlineTtsCoordinator.setPlaybackMode(mode)
        offlineTtsCoordinator.setPlaybackMode(mode)
        onlineTtsCoordinator.clear()
        offlineTtsCoordinator.clear()
    }

    override fun onCleared() {
        release()
    }

    fun release() {
        if (released) return
        released = true
        onlineGeneration.incrementAndGet()
        offlineGeneration.incrementAndGet()
        prepared = false
        cancelRuntimeOperations()
        mainHandler.removeCallbacks(rowsPublisher)
        rowsPublishPending.set(false)
        stopAudioCapture()
        synchronized(ttsSelectionLock) {
            onlineTtsCoordinator.release()
            offlineTtsCoordinator.release()
        }
        TmkTranslationSDK.cancelOfflineModelDownload()
        synchronized(mapper) { mapper.clear() }
        // Concurrent 页面只有这一处执行 SDK 级释放，Runtime 不单独 release。
        TmkTranslationSDK.releaseChannel()
        onlineChannel = null
        offlineChannel = null
        onlineListener = null
        offlineListener = null
    }

    private fun prepareOnline(generation: Long = onlineGeneration.get()) {
        if (!isCurrent(ConcurrentConversationMapper.Runtime.ONLINE, generation)) return
        val profile = OneToOneDemoDefaults.concurrentOnline
        // 两个平台统一的业务语义：左路固定 PCM 为 target，右路麦克风为 source。
        // 在线一对一统一语义：SDK sourceLang=右路/对方，targetLang=左路/自己。
        val roomConfig = TmkTranslationRoomConfig.Builder()
            .setScenario(Scenario.ONE_TO_ONE)
            .setSourceLang(rightLang)
            .setTargetLang(leftLang)
            .setSpeakers(listOf(TmkSpeaker(SpeakerChannel.LEFT, profile.leftSpeaker), TmkSpeaker(SpeakerChannel.RIGHT, profile.rightSpeaker)))
            .setOnlineTranslateEngine(profile.translateEngine)
            .setOnlineRecognizeEngine(profile.recognizeEngine)
            .setRoomScenario(profile.roomScenario)
            .setTranslateMode(profile.translateMode)
            .setDialogConversationAudioMode(profile.audioMode)
            .setEnableSensitiveWordRedaction(if (DemoSettingsStore.loadSensitiveWordRedactionEnabled(application)) TmkSensitiveWordRedactionOption.ENABLED else TmkSensitiveWordRedactionOption.DISABLED)
            .build()
        onlineRoomOperation = TmkTranslationSDK.createTmkTranslationRoom(roomConfig, object : CreateRoomCallback {
            override fun onSuccess(room: TmkTranslationRoom) {
                if (!isCurrent(ConcurrentConversationMapper.Runtime.ONLINE, generation)) return
                onlineRoomOperation = null
                Log.d(TAG, "runtime=ONLINE room created")
                val config = TmkTransChannelConfig.Builder()
                    .setRoom(room)
                    .setMode(TranslationMode.ONLINE)
                    .setScenario(Scenario.ONE_TO_ONE)
                    .setTransModeType(TransModeType.ONE_TO_ONE)
                    .setSourceLang(rightLang)
                    .setTargetLang(leftLang)
                    .setSpeakers(listOf(TmkSpeaker(SpeakerChannel.LEFT, profile.leftSpeaker), TmkSpeaker(SpeakerChannel.RIGHT, profile.rightSpeaker)))
                    .setOnlineTranslateEngine(profile.translateEngine)
                    .setRoomScenario(profile.roomScenario)
                    .setSampleRate(SAMPLE_RATE)
                    .setChannelNum(CHANNEL_COUNT)
                    .build()
                createChannel(config, ConcurrentConversationMapper.Runtime.ONLINE, generation)
            }

            override fun onError(errorId: Int, e: Exception) {
                if (!isCurrent(ConcurrentConversationMapper.Runtime.ONLINE, generation)) return
                onlineRoomOperation = null
                Log.e(TAG, "runtime=ONLINE room creation failed code=$errorId")
            publish { it.copy(onlineStatus = "创建房间失败：${e.message}", onlineCanRetry = true) }
            }
        })
    }

    private fun prepareOffline(generation: Long = offlineGeneration.get()) {
        if (!isCurrent(ConcurrentConversationMapper.Runtime.OFFLINE, generation)) return
        if (!TmkTranslationSDK.isOfflineTranslationSupported()) {
            publish { it.copy(offlineStatus = "当前账号未开通离线能力", modelStatus = "不可用", needsModelDownload = false, offlineCanRetry = false) }
            return
        }
        if (!TmkTranslationSDK.isOfflineModelReady(rightLang, leftLang, Scenario.ONE_TO_ONE, true, true)) {
            publish { it.copy(offlineStatus = "模型缺失", modelStatus = "需要下载", needsModelDownload = true, offlineCanRetry = false) }
            return
        }
        val profile = OneToOneDemoDefaults.concurrentOffline
        TmkTranslationSDK.createTmkTranslationRoom(object : CreateRoomCallback {
            override fun onSuccess(room: TmkTranslationRoom) {
                if (!isCurrent(ConcurrentConversationMapper.Runtime.OFFLINE, generation)) return
                Log.d(TAG, "runtime=OFFLINE room created")
                // 离线 SDK 的 Channel 字段是模型主方向 source→target；引擎内部展开为
                // 左路 target→source、右路 source→target，与 iOS 使用同一业务语义。
                val config = TmkTransChannelConfig.Builder()
                    .setRoom(room)
                    .setMode(TranslationMode.OFFLINE)
                    .setScenario(Scenario.ONE_TO_ONE)
                    .setSourceLang(rightLang)
                    .setTargetLang(leftLang)
                    .setSpeakers(listOf(TmkSpeaker(SpeakerChannel.LEFT, profile.leftSpeaker), TmkSpeaker(SpeakerChannel.RIGHT, profile.rightSpeaker)))
                    .setSampleRate(SAMPLE_RATE)
                    .setChannelNum(CHANNEL_COUNT)
                    .setOfflineAudioChannelMode(profile.audioMode)
                    .setModelRootDirectory(TmkTranslationSDK.defaultOfflineModelRootDirectory(application))
                    .setTranslateMode(profile.translateMode)
                    .setRoomScenario(profile.roomScenario)
                    .build()
                createChannel(config, ConcurrentConversationMapper.Runtime.OFFLINE, generation)
            }

            override fun onError(errorId: Int, e: Exception) {
                if (!isCurrent(ConcurrentConversationMapper.Runtime.OFFLINE, generation)) return
                Log.e(TAG, "runtime=OFFLINE room creation failed code=$errorId")
            publish { it.copy(offlineStatus = "创建房间失败：${e.message}", offlineCanRetry = true) }
            }
        })
    }

    private fun createChannel(
        config: TmkTransChannelConfig,
        runtime: ConcurrentConversationMapper.Runtime,
        generation: Long,
    ) {
        if (!isCurrent(runtime, generation)) return
        val listener = listenerFor(runtime, generation)
        when (runtime) {
            ConcurrentConversationMapper.Runtime.ONLINE -> onlineListener = listener
            ConcurrentConversationMapper.Runtime.OFFLINE -> offlineListener = listener
        }
        val operation = TmkTranslationSDK.createTranslationChannel(application, config, listener, object : CreateChannelCallback {
            override fun onSuccess(channel: TmkTranslationChannel) {
                if (!isCurrent(runtime, generation)) {
                    channel.destroy()
                    return
                }
                when (runtime) {
                    ConcurrentConversationMapper.Runtime.ONLINE -> onlineChannelOperation = null
                    ConcurrentConversationMapper.Runtime.OFFLINE -> offlineChannelOperation = null
                }
                when (runtime) {
                    ConcurrentConversationMapper.Runtime.ONLINE -> onlineChannel = channel
                    ConcurrentConversationMapper.Runtime.OFFLINE -> offlineChannel = channel
                }
                Log.d(TAG, "runtime=$runtime channel created and listener bound")
                publish {
                    when (runtime) {
                        ConcurrentConversationMapper.Runtime.ONLINE -> it.copy(onlineStatus = "已就绪", onlineCanRetry = false, canStart = true)
                        ConcurrentConversationMapper.Runtime.OFFLINE -> it.copy(offlineStatus = "已就绪", offlineCanRetry = false, modelStatus = "模型已就绪", needsModelDownload = false, isModelDownloading = false, canStart = true)
                    }
                }
            }

            override fun onError(errorId: Int, e: Exception) {
                if (!isCurrent(runtime, generation)) return
                when (runtime) {
                    ConcurrentConversationMapper.Runtime.ONLINE -> onlineChannelOperation = null
                    ConcurrentConversationMapper.Runtime.OFFLINE -> offlineChannelOperation = null
                }
                when (runtime) {
                    ConcurrentConversationMapper.Runtime.ONLINE -> onlineListener = null
                    ConcurrentConversationMapper.Runtime.OFFLINE -> offlineListener = null
                }
                Log.e(TAG, "runtime=$runtime channel creation failed code=$errorId")
                publish {
                    when (runtime) {
                        ConcurrentConversationMapper.Runtime.ONLINE -> it.copy(onlineStatus = "创建通道失败：${e.message}", onlineCanRetry = true)
                        ConcurrentConversationMapper.Runtime.OFFLINE -> it.copy(offlineStatus = "创建通道失败：${e.message}", offlineCanRetry = true)
                    }
                }
            }
        }, TmkCreateChannelOptions.defaultConfig())
        when (runtime) {
            ConcurrentConversationMapper.Runtime.ONLINE -> onlineChannelOperation = operation
            ConcurrentConversationMapper.Runtime.OFFLINE -> offlineChannelOperation = operation
        }
    }

    private fun listenerFor(runtime: ConcurrentConversationMapper.Runtime, generation: Long): TmkTranslationListener = object : TmkTranslationListener {
        override fun onRecognized(fromEngine: AbstractChannelEngine?, r: Result<String>?, isFinal: Boolean) = consume(runtime, generation, ConcurrentConversationMapper.Kind.ASR, r, isFinal)
        override fun onTranslate(fromEngine: AbstractChannelEngine?, r: Result<String>?, isFinal: Boolean) = consume(runtime, generation, ConcurrentConversationMapper.Kind.MT, r, isFinal)
        override fun onAudioDataReceive(fromEngine: AbstractChannelEngine?, r: Result<String>?, data: ByteArray, channelCount: Int) {
            // SDK 的 TTS 回调通过 data 参数传音频，Result 只携带音频路由元数据，不要求 data 标记。
            synchronized(ttsSelectionLock) {
                // 播放条件是 Runtime 来源和左右路两个维度同时匹配，不能按任一条件单独放行。
                if (!isCurrent(runtime, generation) || data.isEmpty() || !isTtsSourceSelected(runtime)) return
                val coordinator = if (runtime == ConcurrentConversationMapper.Runtime.ONLINE) {
                    onlineTtsCoordinator
                } else {
                    offlineTtsCoordinator
                }
                coordinator.handleAudioData(r, data, channelCount)
            }
        }
        override fun onError(code: Int, msg: String) = publishRuntimeError(runtime, generation, msg)
        override fun onEvent(eventName: String, args: Any?) = Unit
        override fun onStateChanged(fromEngine: AbstractChannelEngine?, snapshot: TmkTranslationChannelStateSnapshot) = Unit
    }

    private fun consume(runtime: ConcurrentConversationMapper.Runtime, generation: Long, kind: ConcurrentConversationMapper.Kind, result: Result<String>?, isFinal: Boolean) {
        if (!isCurrent(runtime, generation)) return
        val result = result ?: return
        val firstResultLogged = if (runtime == ConcurrentConversationMapper.Runtime.ONLINE) {
            onlineFirstResultLogged
        } else {
            offlineFirstResultLogged
        }
        if (firstResultLogged.compareAndSet(false, true)) {
            // 只记录首个回调的运行时和类型，不记录识别文本，便于区分建链失败与 Listener 未到达。
            Log.d(TAG, "runtime=$runtime listener callback kind=$kind final=$isFinal")
        }
        val lane = result.extraData?.get("channel")?.toString()?.lowercase()
        val fallbackLanguages = if (runtime == ConcurrentConversationMapper.Runtime.ONLINE) {
            when (lane) {
                "1", "left" -> leftLang to rightLang
                "2", "right" -> rightLang to leftLang
                else -> rightLang to leftLang
            }
        } else {
            rightLang to leftLang
        }
        val event = when (kind) {
            ConcurrentConversationMapper.Kind.ASR -> DemoConversationEventAdapter.makeRecognizedEvent(
                result = result,
                isFinal = isFinal,
                fallbackSourceLangCode = fallbackLanguages.first,
                fallbackTargetLangCode = fallbackLanguages.second,
            )
            ConcurrentConversationMapper.Kind.MT -> DemoConversationEventAdapter.makeTranslatedEvent(
                result = result,
                isFinal = isFinal,
                fallbackSourceLangCode = fallbackLanguages.first,
                fallbackTargetLangCode = fallbackLanguages.second,
            )
        } ?: return
        // Adapter 校验 bubble_id/session_id/chunk_id 后再进入各 Runtime 独立聚合器。
        synchronized(mapper) {
            mapper.consume(runtime, event)
        }
        requestRowsPublish()
    }

    private fun publishRuntimeError(runtime: ConcurrentConversationMapper.Runtime, generation: Long, message: String) {
        if (!isCurrent(runtime, generation)) return
        publish {
            if (runtime == ConcurrentConversationMapper.Runtime.ONLINE) it.copy(onlineStatus = "错误：$message", onlineCanRetry = true)
            else it.copy(offlineStatus = "错误：$message", offlineCanRetry = true)
        }
    }

    private fun formatBytes(bytes: Long): String {
        if (bytes < 1024L) return "$bytes B"
        val units = arrayOf("B", "KB", "MB", "GB")
        var value = bytes.toDouble()
        var index = 0
        while (value >= 1024.0 && index < units.lastIndex) {
            value /= 1024.0
            index++
        }
        return String.format(Locale.US, "%.1f %s", value, units[index])
    }

    private fun startAudioCapture() {
        val bufferSize = AudioRecord.getMinBufferSize(SAMPLE_RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
        if (bufferSize <= 0) {
            publish { it.copy(captureStatus = "音频设备不可用") }
            return
        }
        val record = try {
            AudioRecord(MediaRecorder.AudioSource.MIC, SAMPLE_RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT, bufferSize)
        } catch (_: Exception) {
            publish { it.copy(captureStatus = "音频设备初始化失败") }
            return
        }
        if (record.state != AudioRecord.STATE_INITIALIZED) {
            record.release()
            publish { it.copy(captureStatus = "音频设备初始化失败") }
            return
        }
        val detector = try {
            VadDetector(sampleRate = SAMPLE_RATE).apply {
                setCallback(object : VadDetector.Callback {
                    override fun onVadStart() { pendingRightMetadata = newUtterance(ConcurrentConversationMapper.Lane.RIGHT) }
                    override fun onVadEnd() = Unit
                })
                init()
            }
        } catch (_: Exception) {
            record.release()
            publish { it.copy(captureStatus = "VAD 初始化失败") }
            return
        }
        synchronized(audioCaptureLock) {
            audioRecord = record
            rightVad = detector
            isRecording = true
        }
        try {
            record.startRecording()
        } catch (_: Exception) {
            stopAudioCapture()
            publish { it.copy(captureStatus = "音频启动失败") }
            return
        }
        val worker = Thread({ captureLoop(record, detector) }, "Concurrent1v1-Audio")
        synchronized(audioCaptureLock) { recordingThread = worker }
        worker.start()
        onlineTtsCoordinator.setActive(true)
        offlineTtsCoordinator.setActive(true)
        publish { it.copy(isRunning = true, captureStatus = "采集中") }
    }

    private fun captureLoop(record: AudioRecord, detector: VadDetector) {
        val left = ByteArray(BYTES_PER_20_MS)
        val right = ByteArray(BYTES_PER_20_MS)
        val loop = DemoLocalAudioLoopBuffer(readDemoPcmAsset("en_simple.pcm"))
        try {
            captureLoop@ while (isRecording && !Thread.currentThread().isInterrupted) {
                val leftStarted = loop.fillNextLoopChunk(left)
                var read = 0
                while (read < right.size && isRecording && !Thread.currentThread().isInterrupted) {
                    val current = runCatching {
                        record.read(right, read, right.size - read)
                    }.getOrDefault(-1)
                    if (current > 0) {
                        read += current
                    } else {
                        // stop/release 会让 read 返回负值；立即退出，避免后台线程空转。
                        break@captureLoop
                    }
                }
                if (read <= 0) continue
                runCatching { detector.pushAudioBytes(right) }
                // 每个循环创建一帧只读 PCM，避免 SDK 异步消费时读取下一轮写入的数据。
                val stereo = ByteArray(BYTES_PER_20_MS * 2)
                for (index in 0 until BYTES_PER_20_MS step 2) {
                    val output = index * 2
                    stereo[output] = left[index]; stereo[output + 1] = left[index + 1]
                    stereo[output + 2] = right[index]; stereo[output + 3] = right[index + 1]
                }
                val metadata = if (leftStarted) newUtterance(ConcurrentConversationMapper.Lane.LEFT) else pendingRightMetadata.also { pendingRightMetadata = null }
                onlineChannel?.pushStreamAudioData(stereo, 2, metadata)
                offlineChannel?.pushStreamAudioData(stereo, 2, metadata)
            }
        } finally {
            // 只由采集线程 release；stopAudioCapture 不在 UI 线程 join/release，避免 read/stop 竞态。
            runCatching { record.stop() }
            runCatching { record.release() }
            runCatching { detector.release() }
            synchronized(audioCaptureLock) {
                if (audioRecord === record) audioRecord = null
                if (rightVad === detector) rightVad = null
                if (recordingThread === Thread.currentThread()) {
                    recordingThread = null
                    isRecording = false
                }
                pendingRightMetadata = null
            }
            publish { state ->
                if (state.isRunning && !isRecording) state.copy(isRunning = false, captureStatus = "采集线程已停止") else state
            }
        }
    }

    private fun newUtterance(lane: ConcurrentConversationMapper.Lane): ByteArray {
        val now = Calendar.getInstance()
        val channel = if (lane == ConcurrentConversationMapper.Lane.LEFT) 1 else 2
        // 这里只发送 SDK 需要的 speechStart 元数据；气泡由各 Runtime 自己的结果回调创建。
        return byteArrayOf(
            channel.toByte(),
            now.get(Calendar.HOUR_OF_DAY).toByte(),
            now.get(Calendar.MINUTE).toByte(),
            now.get(Calendar.SECOND).toByte(),
        )
    }

    private fun stopAudioCapture() {
        isRecording = false
        onlineTtsCoordinator.setActive(false)
        offlineTtsCoordinator.setActive(false)
        val (worker, record, detector) = synchronized(audioCaptureLock) {
            Triple(recordingThread, audioRecord, rightVad)
        }
        runCatching { record?.stop() }
        worker?.interrupt()
        pendingRightMetadata = null
        // 正常路径由 captureLoop finally 完成 release；尚未启动 worker 时由当前线程兜底。
        if (worker == null) {
            runCatching { record?.release() }
            runCatching { detector?.release() }
            synchronized(audioCaptureLock) {
                if (audioRecord === record) audioRecord = null
                if (rightVad === detector) rightVad = null
            }
        }
        if (state.value.isRunning) publish { it.copy(isRunning = false, captureStatus = "已停止") }
    }

    private fun readDemoPcmAsset(name: String): ByteArray? = try {
        application.assets.open(name).use { it.readBytes() }
    } catch (_: Exception) { null }

    private fun publish(transform: (UiState) -> UiState) {
        synchronized(stateLock) {
            if (!released) _state.value = transform(_state.value)
        }
    }

    private fun requestRowsPublish() {
        if (rowsPublishPending.compareAndSet(false, true)) {
            mainHandler.postDelayed(rowsPublisher, 100L)
        }
    }

    private fun cancelRuntimeOperations() {
        onlineRoomOperation?.cancel()
        onlineRoomOperation = null
        onlineChannelOperation?.cancel()
        onlineChannelOperation = null
        offlineChannelOperation?.cancel()
        offlineChannelOperation = null
    }

    private fun isTtsSourceSelected(runtime: ConcurrentConversationMapper.Runtime): Boolean = when (runtime) {
        ConcurrentConversationMapper.Runtime.ONLINE -> state.value.ttsSource == TtsSource.ONLINE
        ConcurrentConversationMapper.Runtime.OFFLINE -> state.value.ttsSource == TtsSource.OFFLINE
    }

    private fun isCurrent(runtime: ConcurrentConversationMapper.Runtime, generation: Long): Boolean {
        if (released) return false
        return when (runtime) {
            ConcurrentConversationMapper.Runtime.ONLINE -> onlineGeneration.get() == generation
            ConcurrentConversationMapper.Runtime.OFFLINE -> offlineGeneration.get() == generation
        }
    }
}
