package co.timekettle.translation.sample

import co.timekettle.translation.model.Result

/** TTS 播放场景。LISTEN=收听(单路直接播放)，ONE_TO_ONE=一对一(按播放音源/通道模式选路)。 */
enum class DemoTtsScene { LISTEN, ONE_TO_ONE }

/** 翻译运行时类型，用于区分在线/离线一对一的路由解析差异。仅 ONE_TO_ONE 场景有意义。 */
enum class DemoTtsRuntime { ONLINE, OFFLINE }

/**
 * 统一的下行 TTS 播放封装，接管 [TmkTranslationListener.onAudioDataReceive] 的全部音频数据。
 *
 * 在类内部消化「守卫 → 选路 → 播放」：
 * - LISTEN：直接播放整帧；可选按目标语言 code 前缀过滤；离线收听按 extraData["sample_rate"] 动态取采样率。
 * - ONE_TO_ONE：按 [runtime] 解析 audio_route/speaker_channel/channel，经 [OneToOnePlaybackSelector]
 *   按播放音源选路(标准=立体声拆一路，低延迟=左右单路帧按音源过滤)，输出可直接播放的 PCM。
 *
 * 各 ViewModel 的 onAudioDataReceive 只需一行 handleAudioData 调用；start/stop 时同步 setActive，
 * 切换播放音源时调用 setPlaybackMode，释放时调用 release。
 */
class DemoTtsPlaybackCoordinator(
    private val tag: String,
    private val scene: DemoTtsScene,
    private val runtime: DemoTtsRuntime = DemoTtsRuntime.ONLINE,
    sampleRate: Int = OneToOneDemoDefaults.sampleRate,
    private val onPlaybackChannelsChanged: ((Int) -> Unit)? = null,
) {
    private val queuePlayer = OneToOneTtsQueuePlayer(tag = tag, sampleRate = sampleRate)
    private val defaultSampleRate = sampleRate

    /** 将 active 检查、选路和入队串行化，防止后台 TTS 回调在 stop 后重新启动播放器。 */
    private val stateLock = Any()
    private var active = false
    private var playbackMode = OneToOnePlaybackMode.LEFT

    /** 是否处于翻译中，由 VM 在 start/stop 时同步；非活跃期丢弃迟到的音频帧。 */
    fun setActive(active: Boolean) = synchronized(stateLock) {
        this.active = active
        if (!active) queuePlayer.clearQueue()
    }

    /** 切换本机播放音源(左路/右路翻译)。切换时终止当前帧与待播队列，避免残留反声道数据。 */
    fun setPlaybackMode(mode: OneToOnePlaybackMode) = synchronized(stateLock) {
        if (playbackMode == mode) return@synchronized
        playbackMode = mode
        queuePlayer.stop()
    }

    /** 清空待播队列(切换 TTS 来源等场景丢弃残留音频)，不停止播放线程。 */
    fun clear() = synchronized(stateLock) { queuePlayer.clearQueue() }

    /** 释放底层播放器资源，并使所有已到达但尚未入队的后台 PCM 失效。 */
    fun release() = synchronized(stateLock) {
        active = false
        queuePlayer.stop()
    }

    /** 接管 onAudioDataReceive 的一帧数据，内部完成守卫、选路和原子入队。 */
    fun handleAudioData(r: Result<String>?, data: ByteArray, channelCount: Int) {
        if (data.isEmpty()) return
        val accepted = synchronized(stateLock) {
            if (!active) return@synchronized false
            when (scene) {
                DemoTtsScene.LISTEN -> handleListenLocked(r, data, channelCount)
                DemoTtsScene.ONE_TO_ONE -> handleOneToOneLocked(r, data, channelCount)
            }
        }
        if (accepted) onPlaybackChannelsChanged?.invoke(channelCount)
    }

    private fun handleListenLocked(r: Result<String>?, data: ByteArray, channelCount: Int): Boolean {
        queuePlayer.play(data, channelCount, resolveSampleRate(r))
        return true
    }

    private fun handleOneToOneLocked(r: Result<String>?, data: ByteArray, channelCount: Int): Boolean {
        val extraData = r?.extraData
        when (runtime) {
            DemoTtsRuntime.ONLINE -> {
                val audioRoute = OneToOnePlaybackSelector.AudioRoute.from(extraData?.get("audio_route"))
                val speakerChannel = OneToOnePlaybackSelector.resolveOnlineSpeakerChannel(
                    audioRoute = audioRoute,
                    rawSpeakerChannel = extraData?.get("speaker_channel"),
                )
                val output = OneToOnePlaybackSelector.selectPlaybackData(
                    data = data,
                    channelCount = channelCount,
                    playbackMode = playbackMode,
                    audioRoute = audioRoute,
                    speakerChannel = speakerChannel,
                ) ?: return false
                queuePlayer.play(output.data, output.channelCount)
                return true
            }
            DemoTtsRuntime.OFFLINE -> {
                val audioRoute = OneToOnePlaybackSelector.resolveOfflineAudioRoute(
                    channelCount = channelCount,
                    rawAudioRoute = extraData?.get("audio_route"),
                    rawChannel = extraData?.get("channel"),
                )
                val output = OneToOnePlaybackSelector.selectPlaybackData(
                    data = data,
                    channelCount = channelCount,
                    playbackMode = playbackMode,
                    audioRoute = audioRoute,
                    leftActive = extraData?.get("left_active") as? Boolean,
                    rightActive = extraData?.get("right_active") as? Boolean,
                ) ?: return false
                queuePlayer.play(output.data, output.channelCount)
                return true
            }
        }
    }

    private fun resolveSampleRate(r: Result<String>?): Int {
        val raw = r?.extraData?.get("sample_rate") ?: return defaultSampleRate
        return when (raw) {
            is Number -> raw.toInt()
            is String -> raw.toIntOrNull()
            else -> null
        }?.takeIf { it > 0 } ?: defaultSampleRate
    }
}
