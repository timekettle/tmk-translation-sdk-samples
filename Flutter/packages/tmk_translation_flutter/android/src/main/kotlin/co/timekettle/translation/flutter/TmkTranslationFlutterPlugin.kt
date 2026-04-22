package co.timekettle.translation.flutter

import android.Manifest
import android.app.Application
import android.content.Context
import android.content.pm.PackageManager
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.AudioTrack
import android.media.MediaRecorder
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.core.content.ContextCompat
import co.timekettle.offlinesdk.ModelPaths
import co.timekettle.offlinesdk.OfflineModelManager
import co.timekettle.offlinesdk.diagnosis.SdkDiagnosisManager
import co.timekettle.translation.TmkTranslationChannel
import co.timekettle.translation.TmkTranslationSDK
import co.timekettle.translation.config.TmkTransChannelConfig
import co.timekettle.translation.config.TmkTransGlobalConfig
import co.timekettle.translation.core.AbstractChannelEngine
import co.timekettle.translation.enums.Scenario
import co.timekettle.translation.enums.TranslationMode
import co.timekettle.translation.listener.AuthCallback
import co.timekettle.translation.listener.CreateChannelCallback
import co.timekettle.translation.listener.CreateRoomCallback
import co.timekettle.translation.listener.TmkTranslationListener
import co.timekettle.translation.lingcast.common.enums.TransModeType
import co.timekettle.translation.model.OfflineBubbleManager
import co.timekettle.translation.model.OnlineBubbleManager
import co.timekettle.translation.model.TmkTranslationRoom
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.InputStream
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import kotlin.concurrent.thread

class TmkTranslationFlutterPlugin :
    FlutterPlugin,
    MethodChannel.MethodCallHandler,
    EventChannel.StreamHandler {
    companion object {
        private const val TAG = "TmkTranslationPlugin"
    }


    private lateinit var applicationContext: Context
    private lateinit var methodChannel: MethodChannel
    private lateinit var eventChannel: EventChannel
    private lateinit var settingsStore: TmkSettingsStore
    private val mainHandler = Handler(Looper.getMainLooper())
    private val sessions = ConcurrentHashMap<String, BaseSessionManager>()

    @Volatile
    private var eventSink: EventChannel.EventSink? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        applicationContext = binding.applicationContext
        settingsStore = TmkSettingsStore(applicationContext)
        methodChannel = MethodChannel(
            binding.binaryMessenger,
            "co.timekettle.translation.flutter/methods",
        )
        eventChannel = EventChannel(
            binding.binaryMessenger,
            "co.timekettle.translation.flutter/events",
        )
        methodChannel.setMethodCallHandler(this)
        eventChannel.setStreamHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
        sessions.values.forEach(BaseSessionManager::dispose)
        sessions.clear()
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "getCurrentSettings" -> result.success(settingsStore.load().toMap())
            "initialize" -> handleInitialize(call, result)
            "applySettings" -> handleApplySettings(call, result)
            "verifyAuth" -> handleVerifyAuth(result)
            "getSupportedLanguages" -> handleGetSupportedLanguages(call, result)
            "getRuntimeStatus" -> handleGetRuntimeStatus(result)
            "exportDiagnosisLogs" -> result.success(null)
            "createSession" -> handleCreateSession(call, result)
            "getOfflineModelStatus" -> withSession(call, result) { session ->
                result.success(session.getOfflineModelStatus())
            }
            "downloadOfflineModels" -> withSession(call, result) { session ->
                session.downloadOfflineModels()
                result.success(null)
            }
            "cancelOfflineDownload" -> withSession(call, result) { session ->
                session.cancelOfflineDownload()
                result.success(null)
            }
            "startSession" -> withSession(call, result) { session ->
                session.start()
                result.success(null)
            }
            "stopSession" -> withSession(call, result) { session ->
                session.stop()
                result.success(null)
            }
            "disposeSession" -> withSession(call, result) { session ->
                session.dispose()
                sessions.remove(session.sessionId)
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun handleInitialize(call: MethodCall, result: MethodChannel.Result) {
        try {
            val settings = TmkSettings.fromMap(call.argument<Map<*, *>>("settings")).also(settingsStore::save)
            initializeSdk(call.argument("appId"), call.argument("appSecret"), settings)
            handleGetRuntimeStatus(result)
        } catch (error: Throwable) {
            result.error("sdk_init_failed", error.message, null)
        }
    }

    private fun handleApplySettings(call: MethodCall, result: MethodChannel.Result) {
        try {
            val settings = TmkSettings.fromMap(call.argument<Map<*, *>>("settings")).also(settingsStore::save)
            initializeSdk(call.argument("appId"), call.argument("appSecret"), settings)
            handleGetRuntimeStatus(result)
        } catch (error: Throwable) {
            result.error("apply_settings_failed", error.message, null)
        }
    }

    private fun handleVerifyAuth(result: MethodChannel.Result) {
        TmkTranslationSDK.verifyAuth(object : AuthCallback {
            override fun onSuccess() = result.success(true)

            override fun onError(errorId: Int, e: Exception) {
                result.success(false)
            }
        })
    }

    private fun handleGetSupportedLanguages(call: MethodCall, result: MethodChannel.Result) {
        val source = call.argument<String>("source") ?: "online"
        if (source == "offline") {
            result.success(TranslationLanguages.listFor(source))
            return
        }

        thread(name = "tmk-supported-languages") {
            val payload = runCatching {
                SupportedLanguagesService.fetchOnlineLanguages(
                    baseUrl = SupportedLanguagesService.defaultServiceRootUrl(),
                    uiLocales = listOf("zh-CN"),
                )
            }.getOrElse { error ->
                Log.w(
                    TAG,
                    "getSupportedLanguages online fetch failed, falling back to bundled list: ${error.message}",
                    error,
                )
                TranslationLanguages.listFor("online")
            }
            mainHandler.post {
                result.success(payload)
            }
        }
    }

    private fun handleGetRuntimeStatus(result: MethodChannel.Result) {
        TmkTranslationSDK.verifyAuth(object : AuthCallback {
            override fun onSuccess() {
                result.success(
                    mapOf(
                        "onlineEngineStatus" to mapOf(
                            "kind" to "available",
                            "summary" to "可用",
                            "detail" to "鉴权成功",
                        ),
                        "offlineEngineStatus" to mapOf(
                            "kind" to "placeholder",
                            "summary" to "依赖模型",
                            "detail" to "离线状态由具体语言对的模型就绪情况决定",
                        ),
                        "authInfo" to mapOf(
                            "tokenSummary" to "有效",
                            "tokenDetail" to "鉴权成功，可继续创建通道",
                            "autoRefreshSummary" to "暂无数据",
                            "autoRefreshDetail" to "当前 Android SDK 未暴露自动刷新细节",
                        ),
                        "versionText" to "TmkTranslationSDK v1.0.0",
                    ),
                )
            }

            override fun onError(errorId: Int, e: Exception) {
                val detail = e.message ?: "Unknown error"
                result.success(
                    mapOf(
                        "onlineEngineStatus" to mapOf(
                            "kind" to "unavailable",
                            "summary" to "不可用",
                            "detail" to detail,
                        ),
                        "offlineEngineStatus" to mapOf(
                            "kind" to "unavailable",
                            "summary" to "不可用",
                            "detail" to "依赖鉴权结果",
                        ),
                        "authInfo" to mapOf(
                            "tokenSummary" to "不可用",
                            "tokenDetail" to detail,
                            "autoRefreshSummary" to "暂无数据",
                            "autoRefreshDetail" to "当前 Android SDK 未暴露自动刷新细节",
                        ),
                        "versionText" to "TmkTranslationSDK v1.0.0",
                    ),
                )
            }
        })
    }

    private fun handleCreateSession(call: MethodCall, result: MethodChannel.Result) {
        val config = SessionConfig.fromMap(call.arguments as? Map<*, *> ?: emptyMap<String, Any>())
        val sessionId = UUID.randomUUID().toString()
        val session = when {
            config.mode == "online" && config.scenario == "listen" ->
                OnlineListenSession(sessionId, applicationContext, config, ::emitEvent)
            config.mode == "online" && config.scenario == "one_to_one" ->
                OnlineOneToOneSession(sessionId, applicationContext, config, ::emitEvent)
            config.mode == "offline" && config.scenario == "listen" ->
                OfflineListenSession(sessionId, applicationContext, config, ::emitEvent)
            else ->
                OfflineOneToOneSession(sessionId, applicationContext, config, ::emitEvent)
        }
        sessions[sessionId] = session
        result.success(sessionId)
    }

    private fun initializeSdk(appId: String?, appSecret: String?, settings: TmkSettings) {
        val credentials = resolveCredentials(appId, appSecret)
        SdkDiagnosisManager.setEnabled(settings.diagnosisEnabled)
        SdkDiagnosisManager.setConsoleEnabled(settings.consoleLogEnabled)
        val globalConfig = TmkTransGlobalConfig.Builder()
            .setAuth(credentials.first, credentials.second)
            .build()
        TmkTranslationSDK.sdkInit(applicationContext as Application, globalConfig)
    }

    private fun resolveCredentials(appId: String?, appSecret: String?): Pair<String, String> {
        val resolvedAppId = appId?.trim()?.takeUnless { it.isEmpty() } ?: manifestValue("TMK_SAMPLE_APP_ID")
        val resolvedAppSecret = appSecret?.trim()?.takeUnless { it.isEmpty() } ?: manifestValue("TMK_SAMPLE_APP_SECRET")
        require(resolvedAppId.isNotEmpty()) {
            "Missing TMK_SAMPLE_APP_ID. Set it in Android manifest placeholders or pass it to initialize()."
        }
        require(resolvedAppSecret.isNotEmpty()) {
            "Missing TMK_SAMPLE_APP_SECRET. Set it in Android manifest placeholders or pass it to initialize()."
        }
        return resolvedAppId to resolvedAppSecret
    }

    private fun manifestValue(key: String): String {
        val info = applicationContext.packageManager.getApplicationInfo(
            applicationContext.packageName,
            PackageManager.GET_META_DATA,
        )
        return info.metaData?.getString(key)?.trim().orEmpty()
    }

    private fun withSession(
        call: MethodCall,
        result: MethodChannel.Result,
        block: (BaseSessionManager) -> Unit,
    ) {
        val sessionId = call.argument<String>("sessionId")
        val session = sessionId?.let(sessions::get)
        if (session == null) {
            result.error("missing_session", "Session not found: $sessionId", null)
            return
        }
        block(session)
    }

    private fun emitEvent(kind: String, sessionId: String?, payload: Map<String, Any?>) {
        val event = HashMap<String, Any?>()
        event["kind"] = kind
        if (sessionId != null) {
            event["sessionId"] = sessionId
        }
        event.putAll(payload)
        mainHandler.post {
            eventSink?.success(event)
        }
    }
}

private data class SessionConfig(
    val scenario: String,
    val mode: String,
    val sourceLanguage: String,
    val targetLanguage: String,
    val useFixedAudio: Boolean,
) {
    companion object {
        fun fromMap(raw: Map<*, *>): SessionConfig {
            return SessionConfig(
                scenario = raw["scenario"] as? String ?: "listen",
                mode = raw["mode"] as? String ?: "online",
                sourceLanguage = raw["sourceLanguage"] as? String ?: "zh-CN",
                targetLanguage = raw["targetLanguage"] as? String ?: "en-US",
                useFixedAudio = raw["useFixedAudio"] as? Boolean ?: true,
            )
        }
    }
}

private abstract class BaseSessionManager(
    val sessionId: String,
    protected val context: Context,
    protected val config: SessionConfig,
    private val emitEvent: (String, String?, Map<String, Any?>) -> Unit,
) {
    protected val application = context as Application

    abstract fun start()
    abstract fun stop()

    open fun dispose() {
        stop()
    }

    open fun getOfflineModelStatus(): Map<String, Any> {
        return mapOf(
            "isReady" to true,
            "isSupported" to true,
            "summary" to "在线模式",
            "detail" to "在线模式不依赖本地模型",
        )
    }

    open fun downloadOfflineModels() {
        emitError("unsupported_operation", "当前会话不支持离线模型下载")
    }

    open fun cancelOfflineDownload() {
        log("当前 Android SDK 示例未提供离线下载取消能力", "warning")
    }

    protected fun emitSessionState(
        statusText: String,
        isStarted: Boolean? = null,
        isStarting: Boolean? = null,
        isModelReady: Boolean? = null,
    ) {
        emitEvent(
            "session_state",
            sessionId,
            mapOf(
                "statusText" to statusText,
                "isStarted" to isStarted,
                "isStarting" to isStarting,
                "isModelReady" to isModelReady,
            ),
        )
    }

    protected fun emitBubble(
        bubbleId: String,
        sourceLangCode: String,
        targetLangCode: String,
        isFinal: Boolean,
        sourceText: String? = null,
        translatedText: String? = null,
        channel: String? = null,
    ) {
        emitEvent(
            "bubble",
            sessionId,
            mapOf(
                "bubbleId" to bubbleId,
                "sourceLangCode" to sourceLangCode,
                "targetLangCode" to targetLangCode,
                "isFinal" to isFinal,
                "sourceText" to sourceText,
                "translatedText" to translatedText,
                "channel" to channel,
            ),
        )
    }

    protected fun emitDownload(
        message: String,
        progress: Double? = null,
        stage: String = "downloading",
        isCompleted: Boolean = false,
    ) {
        emitEvent(
            "download",
            sessionId,
            mapOf(
                "message" to message,
                "progress" to progress,
                "stage" to stage,
                "isCompleted" to isCompleted,
            ),
        )
    }

    protected fun emitError(code: String, message: String) {
        emitEvent(
            "error",
            sessionId,
            mapOf(
                "code" to code,
                "message" to message,
            ),
        )
    }

    protected fun log(message: String, level: String = "info") {
        emitEvent(
            "log",
            sessionId,
            mapOf(
                "message" to message,
                "level" to level,
            ),
        )
    }

    protected fun hasRecordPermission(): Boolean {
        return ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) ==
            PackageManager.PERMISSION_GRANTED
    }

    protected fun interleaveStereo(left: ByteArray, right: ByteArray, out: ByteArray) {
        var readIndex = 0
        var writeIndex = 0
        while (readIndex + 1 < left.size && readIndex + 1 < right.size && writeIndex + 3 < out.size) {
            out[writeIndex] = left[readIndex]
            out[writeIndex + 1] = left[readIndex + 1]
            out[writeIndex + 2] = right[readIndex]
            out[writeIndex + 3] = right[readIndex + 1]
            readIndex += 2
            writeIndex += 4
        }
    }
}

private class OnlineListenSession(
    sessionId: String,
    context: Context,
    config: SessionConfig,
    emitEvent: (String, String?, Map<String, Any?>) -> Unit,
) : BaseAudioListenSession(sessionId, context, config, emitEvent) {
    override val mode = TranslationMode.ONLINE
    override val transModeType = TransModeType.LISTEN
    override val scenario: Scenario? = null
    override val extraParams: Map<String, String> = emptyMap()
    override val bubbleManager = OnlineBubbleManager()
}

private class OfflineListenSession(
    sessionId: String,
    context: Context,
    config: SessionConfig,
    emitEvent: (String, String?, Map<String, Any?>) -> Unit,
) : BaseAudioListenSession(sessionId, context, config, emitEvent) {
    override val mode = TranslationMode.OFFLINE
    override val transModeType = TransModeType.LISTEN
    override val scenario: Scenario? = null
    override val bubbleManager = OfflineBubbleManager()
    override val extraParams: Map<String, String>
        get() = mapOf(
            "model_root_dir" to OfflineModelManager.getModelRootDir(context).absolutePath,
        )

    override fun getOfflineModelStatus(): Map<String, Any> {
        val ready = OfflineModelManager.isLanguagePairReady(
            context,
            ModelPaths.langToCode(config.sourceLanguage),
            ModelPaths.langToCode(config.targetLanguage),
            true,
            true,
        )
        return mapOf(
            "isReady" to ready,
            "isSupported" to true,
            "summary" to if (ready) "模型已就绪" else "需要下载模型",
            "detail" to if (ready) {
                "${config.sourceLanguage} → ${config.targetLanguage} 可直接开始离线翻译"
            } else {
                "${config.sourceLanguage} → ${config.targetLanguage} 语言对缺少离线模型"
            },
        )
    }

    override fun downloadOfflineModels() {
        Thread {
            emitDownload("准备下载 ${config.sourceLanguage} → ${config.targetLanguage} 模型", 0.0)
            OfflineModelManager.downloadLanguagePair(
                context = context,
                srcLang = config.sourceLanguage,
                dstLang = config.targetLanguage,
                callback = object : OfflineModelManager.DownloadCallback {
                    override fun onProgress(fileName: String, downloaded: Long, total: Long) {
                        val progress = if (total > 0) downloaded.toDouble() / total.toDouble() else null
                        emitDownload("$fileName ${((progress ?: 0.0) * 100).toInt()}%", progress)
                    }

                    override fun onFileProgress(current: Int, total: Int, fileName: String) {
                        emitDownload("($current/$total) $fileName")
                    }

                    override fun onComplete() {
                        emitDownload(
                            "模型下载完成",
                            progress = 1.0,
                            stage = "completed",
                            isCompleted = true,
                        )
                        emitSessionState("离线模型已就绪", isModelReady = true)
                    }

                    override fun onError(message: String) {
                        emitError("offline_download_failed", message)
                    }
                },
            )
        }.start()
    }
}

private class OnlineOneToOneSession(
    sessionId: String,
    context: Context,
    config: SessionConfig,
    emitEvent: (String, String?, Map<String, Any?>) -> Unit,
) : BaseOneToOneSession(sessionId, context, config, emitEvent) {
    override val mode = TranslationMode.ONLINE
    override val transModeType: TransModeType? = TransModeType.ONE_TO_ONE
    override val scenario = Scenario.ONE_TO_ONE
    override val bubbleManager = OnlineBubbleManager()
    override val extraParams: Map<String, String> = emptyMap()
}

private class OfflineOneToOneSession(
    sessionId: String,
    context: Context,
    config: SessionConfig,
    emitEvent: (String, String?, Map<String, Any?>) -> Unit,
) : BaseOneToOneSession(sessionId, context, config, emitEvent) {
    override val mode = TranslationMode.OFFLINE
    override val transModeType: TransModeType? = null
    override val scenario = Scenario.ONE_TO_ONE
    override val bubbleManager = OfflineBubbleManager()
    override val extraParams: Map<String, String>
        get() = mapOf(
            "model_root_dir" to OfflineModelManager.getModelRootDir(context).absolutePath,
        )

    override fun getOfflineModelStatus(): Map<String, Any> {
        val forward = OfflineModelManager.isLanguagePairReady(
            context,
            ModelPaths.langToCode(config.sourceLanguage),
            ModelPaths.langToCode(config.targetLanguage),
            true,
            true,
        )
        val reverse = OfflineModelManager.isLanguagePairReady(
            context,
            ModelPaths.langToCode(config.targetLanguage),
            ModelPaths.langToCode(config.sourceLanguage),
            true,
            true,
        )
        val ready = forward && reverse
        return mapOf(
            "isReady" to ready,
            "isSupported" to true,
            "summary" to if (ready) "双向模型已就绪" else "需要下载双向模型",
            "detail" to if (ready) {
                "${config.sourceLanguage} ↔ ${config.targetLanguage} 双向离线模型已完整"
            } else {
                "${config.sourceLanguage} ↔ ${config.targetLanguage} 仍缺少离线模型"
            },
        )
    }

    override fun downloadOfflineModels() {
        Thread {
            var failed = false
            fun downloadDirection(src: String, dst: String, label: String) {
                OfflineModelManager.downloadLanguagePair(
                    context = context,
                    srcLang = src,
                    dstLang = dst,
                    callback = object : OfflineModelManager.DownloadCallback {
                        override fun onProgress(fileName: String, downloaded: Long, total: Long) {
                            val progress = if (total > 0) downloaded.toDouble() / total.toDouble() else null
                            emitDownload("$label $fileName ${((progress ?: 0.0) * 100).toInt()}%", progress)
                        }

                        override fun onFileProgress(current: Int, total: Int, fileName: String) {
                            emitDownload("$label ($current/$total) $fileName")
                        }

                        override fun onComplete() = Unit

                        override fun onError(message: String) {
                            failed = true
                            emitError("offline_download_failed", "$label: $message")
                        }
                    },
                )
            }

            emitDownload("准备下载双向离线模型", 0.0)
            downloadDirection(config.sourceLanguage, config.targetLanguage, "正向")
            if (!failed) {
                downloadDirection(config.targetLanguage, config.sourceLanguage, "反向")
            }
            if (!failed) {
                emitDownload(
                    "双向模型下载完成",
                    progress = 1.0,
                    stage = "completed",
                    isCompleted = true,
                )
                emitSessionState("离线双向模型已就绪", isModelReady = true)
            }
        }.start()
    }
}

private abstract class BaseAudioListenSession(
    sessionId: String,
    context: Context,
    config: SessionConfig,
    emitEvent: (String, String?, Map<String, Any?>) -> Unit,
) : BaseSessionManager(sessionId, context, config, emitEvent) {

    protected abstract val mode: TranslationMode
    protected abstract val transModeType: TransModeType
    protected abstract val scenario: Scenario?
    protected abstract val extraParams: Map<String, String>
    protected abstract val bubbleManager: Any

    private var channel: TmkTranslationChannel? = null
    private var audioRecord: AudioRecord? = null
    private var audioTrack: AudioTrack? = null
    @Volatile
    private var isRecording = false

    override fun start() {
        if (!hasRecordPermission()) {
            emitError("record_permission_denied", "请先授予麦克风权限")
            return
        }
        emitSessionState("开始鉴权...", isStarting = true)
        TmkTranslationSDK.verifyAuth(object : AuthCallback {
            override fun onSuccess() {
                emitSessionState("鉴权成功，正在创建房间...", isStarting = true)
                TmkTranslationSDK.createTmkTranslationRoom(object : CreateRoomCallback {
                    override fun onSuccess(room: TmkTranslationRoom) {
                        createChannel(room)
                    }

                    override fun onError(errorId: Int, e: Exception) {
                        emitError("create_room_failed", "[${errorId}] ${e.message}")
                        emitSessionState("创建房间失败", isStarting = false)
                    }
                })
            }

            override fun onError(errorId: Int, e: Exception) {
                emitError("verify_auth_failed", "[${errorId}] ${e.message}")
                emitSessionState("鉴权失败", isStarting = false)
            }
        })
    }

    override fun stop() {
        isRecording = false
        try {
            audioRecord?.stop()
        } catch (_: Throwable) {
        }
        audioRecord?.release()
        audioRecord = null
        try {
            audioTrack?.stop()
        } catch (_: Throwable) {
        }
        audioTrack?.release()
        audioTrack = null
        channel?.stop()
        channel?.destroy()
        channel = null
        emitSessionState("翻译已停止", isStarted = false, isStarting = false)
    }

    private fun createChannel(room: TmkTranslationRoom) {
        val builder = TmkTransChannelConfig.Builder()
            .setRoom(room)
            .setMode(mode)
            .setSourceLang(config.sourceLanguage)
            .setTargetLang(config.targetLanguage)
            .setSampleRate(16_000)
            .setChannelNum(1)
            .setTransModeType(transModeType)
        scenario?.let(builder::setScenario)
        extraParams.forEach(builder::addExtraParams)
        val channelConfig = builder.build()
        TmkTranslationSDK.createTranslationChannel(
            context,
            channelConfig,
            object : CreateChannelCallback {
                override fun onSuccess(createdChannel: TmkTranslationChannel) {
                    channel = createdChannel
                    createdChannel.setTranslationListener(listener)
                    createdChannel.start()
                    startRecording()
                    emitSessionState("翻译中...", isStarted = true, isStarting = false)
                }

                override fun onError(errorId: Int, e: Exception) {
                    emitError("create_channel_failed", "[${errorId}] ${e.message}")
                    emitSessionState("创建通道失败", isStarting = false)
                }
            },
        )
    }

    private val listener = object : TmkTranslationListener {
        override fun onRecognized(fromEngine: AbstractChannelEngine?, r: co.timekettle.translation.model.Result<String>?, isFinal: Boolean) {
            val manager = bubbleManager
            val bubbleId = when (manager) {
                is OnlineBubbleManager -> manager.extractBubbleId(r)
                is OfflineBubbleManager -> manager.extractBubbleId(r)
                else -> ""
            }
            emitBubble(
                bubbleId = bubbleId,
                sourceLangCode = r?.srcCode?.takeIf { it.isNotEmpty() } ?: config.sourceLanguage,
                targetLangCode = r?.dstCode?.takeIf { it.isNotEmpty() } ?: config.targetLanguage,
                isFinal = isFinal,
                sourceText = r?.data,
            )
        }

        override fun onTranslate(fromEngine: AbstractChannelEngine?, r: co.timekettle.translation.model.Result<String>?, isFinal: Boolean) {
            val manager = bubbleManager
            val bubbleId = when (manager) {
                is OnlineBubbleManager -> manager.extractBubbleId(r)
                is OfflineBubbleManager -> manager.extractBubbleId(r)
                else -> ""
            }
            emitBubble(
                bubbleId = bubbleId,
                sourceLangCode = r?.srcCode?.takeIf { it.isNotEmpty() } ?: config.sourceLanguage,
                targetLangCode = r?.dstCode?.takeIf { it.isNotEmpty() } ?: config.targetLanguage,
                isFinal = isFinal,
                translatedText = r?.data,
            )
        }

        override fun onAudioDataReceive(
            fromEngine: AbstractChannelEngine?,
            r: co.timekettle.translation.model.Result<String>?,
            data: ByteArray,
            channelCount: Int,
        ) {
            playAudio(data, channelCount)
        }

        override fun onError(code: Int, msg: String) {
            emitError("translation_error", "[$code] $msg")
            stop()
        }

        override fun onEvent(eventName: String, args: Any?) = Unit
    }

    private fun startRecording() {
        val bufferSize = AudioRecord.getMinBufferSize(
            16_000,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT,
        )
        audioRecord = AudioRecord(
            MediaRecorder.AudioSource.MIC,
            16_000,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT,
            bufferSize,
        )
        audioRecord?.startRecording()
        isRecording = true
        Thread {
            val buffer = ByteArray(bufferSize)
            while (isRecording) {
                val read = audioRecord?.read(buffer, 0, buffer.size) ?: -1
                if (read > 0) {
                    channel?.pushStreamAudioData(buffer.copyOf(read), 1, null)
                }
            }
        }.start()
    }

    private fun playAudio(data: ByteArray, channelCount: Int) {
        val channelMask = if (channelCount == 2) AudioFormat.CHANNEL_OUT_STEREO else AudioFormat.CHANNEL_OUT_MONO
        if (audioTrack == null || audioTrack?.state == AudioTrack.STATE_UNINITIALIZED) {
            audioTrack = AudioTrack.Builder()
                .setAudioFormat(
                    AudioFormat.Builder()
                        .setSampleRate(16_000)
                        .setChannelMask(channelMask)
                        .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                        .build(),
                )
                .setBufferSizeInBytes(
                    AudioTrack.getMinBufferSize(
                        16_000,
                        channelMask,
                        AudioFormat.ENCODING_PCM_16BIT,
                    ),
                )
                .setTransferMode(AudioTrack.MODE_STREAM)
                .build()
            audioTrack?.play()
        }
        audioTrack?.write(data, 0, data.size)
    }
}

private abstract class BaseOneToOneSession(
    sessionId: String,
    context: Context,
    config: SessionConfig,
    emitEvent: (String, String?, Map<String, Any?>) -> Unit,
) : BaseSessionManager(sessionId, context, config, emitEvent) {

    protected abstract val mode: TranslationMode
    protected abstract val transModeType: TransModeType?
    protected abstract val scenario: Scenario
    protected abstract val extraParams: Map<String, String>
    protected abstract val bubbleManager: Any

    private var channel: TmkTranslationChannel? = null
    private var audioRecord: AudioRecord? = null
    private var audioTrack: AudioTrack? = null
    private var assetPcmStream: InputStream? = null
    @Volatile
    private var isStreaming = false

    override fun start() {
        if (!hasRecordPermission()) {
            emitError("record_permission_denied", "请先授予麦克风权限")
            return
        }
        emitSessionState("开始鉴权...", isStarting = true)
        TmkTranslationSDK.verifyAuth(object : AuthCallback {
            override fun onSuccess() {
                TmkTranslationSDK.createTmkTranslationRoom(object : CreateRoomCallback {
                    override fun onSuccess(room: TmkTranslationRoom) {
                        createChannel(room)
                    }

                    override fun onError(errorId: Int, e: Exception) {
                        emitError("create_room_failed", "[${errorId}] ${e.message}")
                        emitSessionState("创建房间失败", isStarting = false)
                    }
                })
            }

            override fun onError(errorId: Int, e: Exception) {
                emitError("verify_auth_failed", "[${errorId}] ${e.message}")
                emitSessionState("鉴权失败", isStarting = false)
            }
        })
    }

    override fun stop() {
        isStreaming = false
        try {
            audioRecord?.stop()
        } catch (_: Throwable) {
        }
        audioRecord?.release()
        audioRecord = null
        try {
            audioTrack?.stop()
        } catch (_: Throwable) {
        }
        audioTrack?.release()
        audioTrack = null
        assetPcmStream?.close()
        assetPcmStream = null
        channel?.stop()
        channel?.destroy()
        channel = null
        emitSessionState("翻译已停止", isStarted = false, isStarting = false)
    }

    private fun createChannel(room: TmkTranslationRoom) {
        val builder = TmkTransChannelConfig.Builder()
            .setRoom(room)
            .setMode(mode)
            .setScenario(scenario)
            .setSourceLang(config.sourceLanguage)
            .setTargetLang(config.targetLanguage)
            .setSampleRate(16_000)
            .setChannelNum(2)
        transModeType?.let(builder::setTransModeType)
        extraParams.forEach(builder::addExtraParams)
        val channelConfig = builder.build()
        TmkTranslationSDK.createTranslationChannel(
            context,
            channelConfig,
            object : CreateChannelCallback {
                override fun onSuccess(createdChannel: TmkTranslationChannel) {
                    channel = createdChannel
                    createdChannel.setTranslationListener(listener)
                    createdChannel.start()
                    startStreaming()
                    emitSessionState("1v1 翻译中...", isStarted = true, isStarting = false)
                }

                override fun onError(errorId: Int, e: Exception) {
                    emitError("create_channel_failed", "[${errorId}] ${e.message}")
                    emitSessionState("创建通道失败", isStarting = false)
                }
            },
        )
    }

    private val listener = object : TmkTranslationListener {
        override fun onRecognized(fromEngine: AbstractChannelEngine?, r: co.timekettle.translation.model.Result<String>?, isFinal: Boolean) {
            val manager = bubbleManager
            val bubbleId = when (manager) {
                is OnlineBubbleManager -> manager.extractBubbleId(r)
                is OfflineBubbleManager -> manager.extractBubbleId(r)
                else -> ""
            }
            emitBubble(
                bubbleId = bubbleId,
                sourceLangCode = r?.srcCode?.takeIf { it.isNotEmpty() } ?: config.sourceLanguage,
                targetLangCode = r?.dstCode?.takeIf { it.isNotEmpty() } ?: config.targetLanguage,
                isFinal = isFinal,
                sourceText = r?.data,
                channel = r?.extraData?.get("channel")?.toString(),
            )
        }

        override fun onTranslate(fromEngine: AbstractChannelEngine?, r: co.timekettle.translation.model.Result<String>?, isFinal: Boolean) {
            val manager = bubbleManager
            val bubbleId = when (manager) {
                is OnlineBubbleManager -> manager.extractBubbleId(r)
                is OfflineBubbleManager -> manager.extractBubbleId(r)
                else -> ""
            }
            emitBubble(
                bubbleId = bubbleId,
                sourceLangCode = r?.srcCode?.takeIf { it.isNotEmpty() } ?: config.sourceLanguage,
                targetLangCode = r?.dstCode?.takeIf { it.isNotEmpty() } ?: config.targetLanguage,
                isFinal = isFinal,
                translatedText = r?.data,
                channel = r?.extraData?.get("channel")?.toString(),
            )
        }

        override fun onAudioDataReceive(
            fromEngine: AbstractChannelEngine?,
            r: co.timekettle.translation.model.Result<String>?,
            data: ByteArray,
            channelCount: Int,
        ) {
            val channelMask = if (channelCount == 2) AudioFormat.CHANNEL_OUT_STEREO else AudioFormat.CHANNEL_OUT_MONO
            if (audioTrack == null || audioTrack?.state == AudioTrack.STATE_UNINITIALIZED) {
                audioTrack = AudioTrack.Builder()
                    .setAudioFormat(
                        AudioFormat.Builder()
                            .setSampleRate(16_000)
                            .setChannelMask(channelMask)
                            .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                            .build(),
                    )
                    .setBufferSizeInBytes(
                        AudioTrack.getMinBufferSize(
                            16_000,
                            channelMask,
                            AudioFormat.ENCODING_PCM_16BIT,
                        ),
                    )
                    .setTransferMode(AudioTrack.MODE_STREAM)
                    .build()
                audioTrack?.play()
            }
            audioTrack?.write(data, 0, data.size)
        }

        override fun onError(code: Int, msg: String) {
            emitError("translation_error", "[$code] $msg")
            stop()
        }

        override fun onEvent(eventName: String, args: Any?) = Unit
    }

    private fun startStreaming() {
        val bufferSize = AudioRecord.getMinBufferSize(
            16_000,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT,
        )
        audioRecord = AudioRecord(
            MediaRecorder.AudioSource.MIC,
            16_000,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT,
            bufferSize,
        )
        audioRecord?.startRecording()
        assetPcmStream = if (config.useFixedAudio) {
            runCatching { context.assets.open("16k16b_en-US.pcm") }.getOrNull()
        } else {
            null
        }
        isStreaming = true
        Thread {
            val micBuffer = ByteArray(bufferSize)
            val pcmBuffer = ByteArray(bufferSize)
            val stereoBuffer = ByteArray(bufferSize * 2)
            while (isStreaming) {
                val micRead = audioRecord?.read(micBuffer, 0, micBuffer.size) ?: -1
                if (micRead <= 0) {
                    continue
                }
                if (assetPcmStream != null) {
                    val assetRead = assetPcmStream?.read(pcmBuffer, 0, micRead) ?: -1
                    if (assetRead < micRead) {
                        pcmBuffer.fill(0, maxOf(assetRead, 0), micRead)
                    }
                } else {
                    pcmBuffer.fill(0)
                }
                interleaveStereo(micBuffer.copyOf(micRead), pcmBuffer.copyOf(micRead), stereoBuffer)
                channel?.pushStreamAudioData(stereoBuffer.copyOf(micRead * 2), 2, null)
            }
        }.start()
    }
}
