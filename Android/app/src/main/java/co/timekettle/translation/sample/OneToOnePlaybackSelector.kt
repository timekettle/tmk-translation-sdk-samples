package co.timekettle.translation.sample

/**
 * 一对一下行 TTS 播放音源选择器(纯逻辑,可单测)。在线与离线一对一 Demo 共用同一套选路规则,
 * 对齐 iOS 在线/离线共用的 `OneToOneTranslatedAudioPlaybackSelector`。
 *
 * 规则(输出恒为可直接播放的 PCM,并带上其真实声道数):
 * 1. 低延迟单声道帧(`audio_route`=left/right):按 SDK 明确给出的播放路由选择，
 *    `speaker_channel` 仅表示原始说话侧，不参与播放选路；对侧丢弃(返回 null)。
 * 2. 立体声(`audio_route`=stereo 或 channelCount>=2 的交织数据):按播放音源拆出对应一路,**输出单声道**。
 * 3. 其余非立体声:直接播放(原样返回,声道数不变)。
 */
object OneToOnePlaybackSelector {

    /**
     * SDK 交付的 TTS 播放声道(extraData["audio_route"] 的取值)。
     * 对齐 iOS `TmkTranslatedAudioRoute`,rawValue 为小写字符串;无该字段或无法解析时为 null。
     */
    enum class AudioRoute(val rawValue: String) {
        STEREO("stereo"),
        LEFT("left"),
        RIGHT("right"),
        ;

        companion object {
            fun from(raw: Any?): AudioRoute? {
                val value = raw?.toString()?.trim()?.lowercase()?.takeIf { it.isNotEmpty() } ?: return null
                return when (value) {
                    "1" -> LEFT
                    "2" -> RIGHT
                    else -> entries.firstOrNull { it.rawValue == value }
                }
            }
        }
    }

    /**
     * 解析离线一对一 TTS 路由。
     *
     * 低延迟单声道结果的旧版本可能只携带 `channel`，而标准模式的立体声结果也会
     * 携带一个代表 canonical lane 的 `channel`。因此只有在确认帧为单声道时才允许
     * 用 `channel` 兜底，避免把标准立体声帧误判成单路而不再拆声道。
     */
    fun resolveOfflineAudioRoute(channelCount: Int, rawAudioRoute: Any?, rawChannel: Any?): AudioRoute? {
        AudioRoute.from(rawAudioRoute)?.let { return it }
        return if (channelCount < 2) AudioRoute.from(rawChannel) else null
    }

    /**
     * 解析在线低延迟帧的原始说话侧。
     *
     * 新版 SDK 直接提供 `speaker_channel`;它用于诊断/追踪，播放选路仍以 `audio_route` 为准。
     * 旧版缺失时由最终播放目标 [audioRoute] 取对侧兜底，仅供兼容调用方。
     * `audio_route=stereo` 不代表单一说话侧，返回 null。
     */
    fun resolveOnlineSpeakerChannel(audioRoute: AudioRoute?, rawSpeakerChannel: Any?): AudioRoute? {
        // `stereo` 表示一帧同时包含左右两路，不能把可能附带的 speaker_channel
        // 当成整帧播放路由，否则标准模式会绕过声道拆分并同时播放两路。
        if (audioRoute == AudioRoute.STEREO) return null
        AudioRoute.from(rawSpeakerChannel)?.let { explicit ->
            if (explicit == AudioRoute.LEFT || explicit == AudioRoute.RIGHT) return explicit
        }
        return when (audioRoute) {
            AudioRoute.LEFT -> AudioRoute.RIGHT
            AudioRoute.RIGHT -> AudioRoute.LEFT
            AudioRoute.STEREO, null -> null
        }
    }

    /**
     * 选择结果:要播放的 PCM 及其真实声道数。
     * 立体声拆分后 [channelCount] 为 1,调用方须按此声道数播放(而非原始帧声道数)。
     */
    data class PlaybackOutput(val data: ByteArray, val channelCount: Int) {
        override fun equals(other: Any?): Boolean {
            if (this === other) return true
            if (other !is PlaybackOutput) return false
            return channelCount == other.channelCount && data.contentEquals(other.data)
        }

        override fun hashCode(): Int = 31 * data.contentHashCode() + channelCount
    }

    /**
     * 选择实际要送去播放的 PCM;返回 null 表示该帧不属于本机播放音源(仅低延迟单路帧),应丢弃。
     *
     * @param audioRoute SDK 交付的 `extraData["audio_route"]`;标准模式通常为 null。
     * @param speakerChannel 在线低延迟帧的原始说话侧 `extraData["speaker_channel"]`。
     */
    fun selectPlaybackData(
        data: ByteArray,
        channelCount: Int,
        playbackMode: OneToOnePlaybackMode,
        audioRoute: AudioRoute?,
        speakerChannel: AudioRoute? = null,
        leftActive: Boolean? = null,
        rightActive: Boolean? = null,
    ): PlaybackOutput? {
        if (data.isEmpty()) return null
        // SDK 的 audio_route 是最终播放目标；它优先于 speaker_channel。
        // 在线双 UID 服务端已把对侧译音交叉下发到该目标连接，不能再次按 speaker_channel 取反。
        when (audioRoute) {
            AudioRoute.LEFT ->
                return if (playbackMode == OneToOnePlaybackMode.LEFT) PlaybackOutput(data, channelCount) else null
            AudioRoute.RIGHT ->
                return if (playbackMode == OneToOnePlaybackMode.RIGHT) PlaybackOutput(data, channelCount) else null
            AudioRoute.STEREO, null -> Unit
        }
        // 旧版 SDK 未提供 audio_route 时，仅对确认的单声道帧保留 speaker_channel 兼容兜底。
        // channelCount>=2 表示交织立体声，即使附带 speaker_channel 也必须继续拆分，
        // 否则会把整帧左右声道一起送入播放器。
        if (channelCount < 2) {
            when (speakerChannel) {
                AudioRoute.LEFT ->
                    return if (playbackMode == OneToOnePlaybackMode.LEFT) PlaybackOutput(data, channelCount) else null
                AudioRoute.RIGHT ->
                    return if (playbackMode == OneToOnePlaybackMode.RIGHT) PlaybackOutput(data, channelCount) else null
                AudioRoute.STEREO, null -> Unit
            }
        }
        // 立体声:按用户选择的播放音源拆一路,输出单声道。
        // left_active/right_active 只描述服务端本帧是否有内容，不能改变用户选择；
        // 否则连续收到“仅右路有内容”的帧时，左路选择也会被偷偷切到右路。
        val split = splitStereoInterleaved16LE(data, channelCount)
        if (split != null) {
            val lane = if (playbackMode == OneToOnePlaybackMode.LEFT) split.left else split.right
            return PlaybackOutput(lane, channelCount = 1)
        }
        // 非立体声:直接播放。
        return PlaybackOutput(data, channelCount)
    }

    /** Samples 内部的 PCM16LE 立体声拆分，避免依赖 SDK 未公开的实现类。 */
    private fun splitStereoInterleaved16LE(data: ByteArray, channelCount: Int): StereoSplit? {
        if (channelCount != 2 || data.size < 4 || data.size % 4 != 0) return null
        val left = ByteArray(data.size / 2)
        val right = ByteArray(data.size / 2)
        var source = 0
        var target = 0
        while (source < data.size) {
            left[target] = data[source]
            left[target + 1] = data[source + 1]
            right[target] = data[source + 2]
            right[target + 1] = data[source + 3]
            source += 4
            target += 2
        }
        return StereoSplit(left, right)
    }

    private data class StereoSplit(val left: ByteArray, val right: ByteArray)
}

/**
 * 一对一本机播放音源(听哪一路翻译)。默认 [LEFT](左路翻译)。
 *
 * @property title UI 展示文案。
 */
enum class OneToOnePlaybackMode(val title: String) {
    LEFT("左路翻译"),
    RIGHT("右路翻译"),
}
