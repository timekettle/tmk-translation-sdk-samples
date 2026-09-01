package co.timekettle.translation.sample

import android.app.Application
import android.os.SystemClock
import android.util.Log
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import co.timekettle.translation.Cancelable
import co.timekettle.translation.TmkTranslationChannel
import co.timekettle.translation.TmkTranslationException
import co.timekettle.translation.TmkTranslationSDK
import co.timekettle.translation.config.TmkCreateChannelOptions
import co.timekettle.translation.config.TmkTransChannelConfig
import co.timekettle.translation.config.TmkTranslationRoomConfig
import co.timekettle.translation.core.AbstractChannelEngine
import co.timekettle.translation.enums.Scenario
import co.timekettle.translation.enums.TmkOnlineRecognizeEngine
import co.timekettle.translation.enums.TmkOnlineTranslateEngine
import co.timekettle.translation.enums.TranslationMode
import co.timekettle.translation.lingcast.common.enums.TransModeType
import co.timekettle.translation.listener.AuthCallback
import co.timekettle.translation.listener.CreateChannelCallback
import co.timekettle.translation.listener.CreateRoomCallback
import co.timekettle.translation.listener.TmkTranslationListener
import co.timekettle.translation.model.Result
import co.timekettle.translation.model.SpeakerChannel
import co.timekettle.translation.model.SpeakerGender
import co.timekettle.translation.model.TmkSpeaker
import co.timekettle.translation.model.TmkTranslationChannelStateSnapshot
import co.timekettle.translation.model.TmkTranslationRoom
import dagger.hilt.android.lifecycle.HiltViewModel
import java.util.concurrent.CopyOnWriteArrayList
import javax.inject.Inject
import kotlin.coroutines.resume
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Job
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withTimeoutOrNull

data class ChannelRaceStressConfig(
    val rounds: Int = 3,
    val overlapDelayMs: Long = 500,
    val successfulChannelHoldMs: Long = 8_000,
    val channelTimeoutMs: Long = 60_000,
    val sourceLang: String = "en-US",
    val targetLang: String = "zh-CN",
)

data class ChannelRaceStressUiState(
    val running: Boolean = false,
    val currentRound: Int = 0,
    val completedRounds: Int = 0,
    val reproducedRounds: Int = 0,
    val protectedRounds: Int = 0,
    val successes: Int = 0,
    val failures: Int = 0,
    val timeouts: Int = 0,
    val status: String = "待开始",
    val logs: List<String> = emptyList(),
)

@HiltViewModel
class ChannelRaceStressViewModel @Inject constructor(
    private val application: Application,
) : ViewModel() {

    private data class ChannelOutcome(
        val label: String,
        val channel: TmkTranslationChannel? = null,
        val errorCode: Int? = null,
        val message: String = "",
        val elapsedMs: Long = 0,
    ) {
        val isSuccess: Boolean get() = channel != null
        val isTimeout: Boolean get() = message.contains("timeout", ignoreCase = true)
    }

    private data class ChannelAttempt(
        val label: String,
        val result: CompletableDeferred<ChannelOutcome>,
    )

    private class RoomCreationFailure(
        val errorCode: Int,
        message: String,
        cause: Throwable,
    ) : Exception(message, cause)

    private val _uiState = MutableStateFlow(ChannelRaceStressUiState())
    val uiState: StateFlow<ChannelRaceStressUiState> = _uiState.asStateFlow()

    private var stressJob: Job? = null
    private val activeCancelables = CopyOnWriteArrayList<Cancelable>()
    private val returnedChannels = CopyOnWriteArrayList<TmkTranslationChannel>()

    fun start(config: ChannelRaceStressConfig) {
        if (stressJob?.isActive == true) return
        val normalized = config.copy(
            rounds = config.rounds.coerceIn(1, 100),
            overlapDelayMs = config.overlapDelayMs.coerceIn(0, 30_000),
            successfulChannelHoldMs = config.successfulChannelHoldMs.coerceIn(0, 60_000),
            channelTimeoutMs = config.channelTimeoutMs.coerceIn(1_000, 120_000),
        )
        _uiState.value = ChannelRaceStressUiState(running = true, status = "初始化 SDK")
        addLog(
            "开始：rounds=${normalized.rounds}, overlap=${normalized.overlapDelayMs}ms, " +
                "hold=${normalized.successfulChannelHoldMs}ms, timeout=${normalized.channelTimeoutMs}ms",
        )
        stressJob = viewModelScope.launch {
            runCatching {
                cleanupRuntime()
                TmkTranslationSDK.sdkInit(application, SampleSdkConfig.globalConfig(application))
                verifyAuth()
                addLog("鉴权成功")

                repeat(normalized.rounds) { index ->
                    val round = index + 1
                    _uiState.update { it.copy(currentRound = round, status = "第 $round 轮运行中") }
                    runRound(round, normalized)
                    if (round < normalized.rounds) delay(1_000)
                }
            }.onFailure { error ->
                if (stressJob?.isActive == true) {
                    addLog("压测中止：${error.message ?: error.javaClass.simpleName}")
                    _uiState.update { it.copy(status = "中止：${error.message ?: "未知错误"}") }
                }
            }
            cleanupRuntime()
            _uiState.update {
                it.copy(
                    running = false,
                    status = when {
                        it.reproducedRounds > 0 -> "仍复现 ${it.reproducedRounds} 轮：A 超时、B 成功"
                        it.protectedRounds > 0 -> "保护生效 ${it.protectedRounds} 轮，未出现 60s 超时"
                        else -> "运行完成，暂未命中竞态窗口"
                    },
                )
            }
        }
    }

    fun stop() {
        val job = stressJob
        stressJob = null
        viewModelScope.launch {
            job?.cancelAndJoin()
            cleanupRuntime()
            _uiState.update { it.copy(running = false, status = "已手动停止") }
            addLog("手动停止并清理 Channel")
        }
    }

    fun clearLogs() {
        _uiState.update { it.copy(logs = emptyList()) }
    }

    private suspend fun runRound(round: Int, config: ChannelRaceStressConfig) {
        addLog("R$round/A：开始建房")
        val roomA = createRoom(round, "A", config)
        addLog("R$round/A：建房成功 room=${roomA.roomId}，启动 Channel")
        val attemptA = startChannel(round, "A", roomA, config)

        delay(config.overlapDelayMs)
        addLog("R$round/B：重叠窗口到达，开始建房")
        val roomB = try {
            createRoom(round, "B", config)
        } catch (error: RoomCreationFailure) {
            if (error.errorCode != TmkTranslationException.ErrorCodes.INVALID_STATE) throw error
            addLog("R$round/B：单飞保护生效 [${error.errorCode}]，未进入共享 RTC/RTM 初始化")
            val a = withTimeoutOrNull(config.channelTimeoutMs + 15_000) { attemptA.result.await() }
            if (a?.isSuccess == true) {
                delay(config.successfulChannelHoldMs)
                TmkTranslationSDK.releaseChannel()
            }
            _uiState.update { state ->
                state.copy(
                    completedRounds = state.completedRounds + 1,
                    protectedRounds = state.protectedRounds + 1,
                    successes = state.successes + if (a?.isSuccess == true) 1 else 0,
                    failures = state.failures + if (a?.isSuccess == true) 0 else 1,
                    timeouts = state.timeouts + if (a?.isTimeout == true) 1 else 0,
                )
            }
            cleanupRuntime()
            return
        }
        addLog("R$round/B：建房成功 room=${roomB.roomId}，启动 Channel")
        val attemptB = startChannel(round, "B", roomB, config)

        val releaseB = viewModelScope.launch {
            val outcome = attemptB.result.await()
            if (outcome.isSuccess) {
                delay(config.successfulChannelHoldMs)
                addLog("R$round/B：保持结束，调用 SDK.releaseChannel()")
                TmkTranslationSDK.releaseChannel()
            }
        }

        val waitBudget = config.channelTimeoutMs + config.successfulChannelHoldMs + 15_000
        val outcomes = withTimeoutOrNull(waitBudget) {
            listOf(
                async { attemptA.result.await() },
                async { attemptB.result.await() },
            ).awaitAll()
        }
        releaseB.cancelAndJoin()

        if (outcomes == null) {
            addLog("R$round：页面等待保护超时 ${waitBudget}ms，强制清理")
            _uiState.update { it.copy(failures = it.failures + 1) }
        } else {
            val a = outcomes.first { it.label == "A" }
            val b = outcomes.first { it.label == "B" }
            val reproduced = a.isTimeout && b.isSuccess
            if (reproduced) addLog("R$round：★ 已复现：A timeout + B success")
            _uiState.update { state ->
                state.copy(
                    completedRounds = state.completedRounds + 1,
                    reproducedRounds = state.reproducedRounds + if (reproduced) 1 else 0,
                    successes = state.successes + outcomes.count { it.isSuccess },
                    failures = state.failures + outcomes.count { !it.isSuccess },
                    timeouts = state.timeouts + outcomes.count { it.isTimeout },
                )
            }
        }
        cleanupRuntime()
    }

    private suspend fun verifyAuth() = suspendCancellableCoroutine<Unit> { continuation ->
        TmkTranslationSDK.verifyAuth(object : AuthCallback {
            override fun onSuccess() {
                if (continuation.isActive) continuation.resume(Unit)
            }

            override fun onError(errorId: Int, e: Exception) {
                if (continuation.isActive) {
                    continuation.resumeWith(kotlin.Result.failure(Exception("鉴权失败 [$errorId] ${e.message}", e)))
                }
            }
        })
    }

    private suspend fun createRoom(
        round: Int,
        label: String,
        config: ChannelRaceStressConfig,
    ): TmkTranslationRoom = suspendCancellableCoroutine { continuation ->
        val languages = OnlineOneToOneLanguageMapping.fromDemoSelection(
            sourceLang = config.sourceLang,
            targetLang = config.targetLang,
        )
        val roomConfig = TmkTranslationRoomConfig.Builder()
            .setScenario(Scenario.ONE_TO_ONE)
            .setSourceLang(languages.leftLang)
            .setTargetLang(languages.rightLang)
            .setSpeakers(defaultSpeakers())
            .setOnlineTranslateEngine(TmkOnlineTranslateEngine.AUTOMATIC)
            .setOnlineRecognizeEngine(TmkOnlineRecognizeEngine.THREE_STAGE)
            .build()
        val cancelable = TmkTranslationSDK.createTmkTranslationRoom(
            roomConfig,
            object : CreateRoomCallback {
                override fun onSuccess(room: TmkTranslationRoom) {
                    if (continuation.isActive) continuation.resume(room)
                }

                override fun onError(errorId: Int, e: Exception) {
                    if (continuation.isActive) {
                        continuation.resumeWith(
                            kotlin.Result.failure(
                                RoomCreationFailure(
                                    errorCode = errorId,
                                    message = "R$round/$label 建房失败 [$errorId] ${e.message}",
                                    cause = e,
                                ),
                            ),
                        )
                    }
                }
            },
        )
        activeCancelables += cancelable
        continuation.invokeOnCancellation { cancelable.cancel() }
    }

    private fun startChannel(
        round: Int,
        label: String,
        room: TmkTranslationRoom,
        config: ChannelRaceStressConfig,
    ): ChannelAttempt {
        val result = CompletableDeferred<ChannelOutcome>()
        val startedAt = SystemClock.elapsedRealtime()
        val languages = OnlineOneToOneLanguageMapping.fromDemoSelection(
            sourceLang = config.sourceLang,
            targetLang = config.targetLang,
        )
        val channelConfig = TmkTransChannelConfig.Builder()
            .setRoom(room)
            .setMode(TranslationMode.ONLINE)
            .setScenario(Scenario.ONE_TO_ONE)
            .setTransModeType(TransModeType.ONE_TO_ONE)
            .setSourceLang(languages.leftLang)
            .setTargetLang(languages.rightLang)
            .setSpeakers(defaultSpeakers())
            .setOnlineTranslateEngine(TmkOnlineTranslateEngine.AUTOMATIC)
            .setSampleRate(16_000)
            .setChannelNum(2)
            .addExtraParams("stress_attempt", "R$round-$label")
            .build()
        val cancelable = TmkTranslationSDK.createTranslationChannel(
            application,
            channelConfig,
            stressListener(round, label),
            object : CreateChannelCallback {
                override fun onSuccess(channel: TmkTranslationChannel) {
                    val elapsed = SystemClock.elapsedRealtime() - startedAt
                    returnedChannels += channel
                    addLog("R$round/$label：Channel success ${elapsed}ms")
                    result.complete(ChannelOutcome(label, channel = channel, elapsedMs = elapsed))
                }

                override fun onError(errorId: Int, e: Exception) {
                    val elapsed = SystemClock.elapsedRealtime() - startedAt
                    val message = e.message ?: e.javaClass.simpleName
                    addLog("R$round/$label：Channel error [$errorId] ${elapsed}ms $message")
                    result.complete(
                        ChannelOutcome(
                            label = label,
                            errorCode = errorId,
                            message = message,
                            elapsedMs = elapsed,
                        ),
                    )
                }
            },
            TmkCreateChannelOptions(timeoutMs = config.channelTimeoutMs),
        )
        activeCancelables += cancelable
        return ChannelAttempt(label, result)
    }

    private fun stressListener(round: Int, label: String) = object : TmkTranslationListener {
        override fun onRecognized(fromEngine: AbstractChannelEngine?, r: Result<String>?, isFinal: Boolean) = Unit
        override fun onTranslate(fromEngine: AbstractChannelEngine?, r: Result<String>?, isFinal: Boolean) = Unit
        override fun onAudioDataReceive(
            fromEngine: AbstractChannelEngine?,
            r: Result<String>?,
            data: ByteArray,
            channelCount: Int,
        ) = Unit

        override fun onError(code: Int, msg: String) {
            addLog("R$round/$label listener error [$code] $msg")
        }

        override fun onEvent(eventName: String, args: Any?) = Unit

        override fun onStateChanged(
            fromEngine: AbstractChannelEngine?,
            snapshot: TmkTranslationChannelStateSnapshot,
        ) {
            addLog("R$round/$label state=${snapshot.state.rawValue}/${snapshot.reason.rawValue}")
        }
    }

    private fun defaultSpeakers(): List<TmkSpeaker> = listOf(
        TmkSpeaker(SpeakerChannel.LEFT, SpeakerGender.FEMALE),
        TmkSpeaker(SpeakerChannel.RIGHT, SpeakerGender.MALE),
    )

    private fun cleanupRuntime() {
        activeCancelables.forEach { runCatching { it.cancel() } }
        activeCancelables.clear()
        runCatching { TmkTranslationSDK.releaseChannel() }
        returnedChannels.forEach { runCatching { it.destroy() } }
        returnedChannels.clear()
    }

    private fun addLog(message: String) {
        val line = "%6dms  %s".format(SystemClock.elapsedRealtime() % 1_000_000, message)
        Log.i(TAG, message)
        _uiState.update { state -> state.copy(logs = (state.logs + line).takeLast(MAX_LOG_LINES)) }
    }

    override fun onCleared() {
        stressJob?.cancel()
        cleanupRuntime()
        super.onCleared()
    }

    private companion object {
        const val TAG = "ChannelRaceStress"
        const val MAX_LOG_LINES = 400
    }
}
