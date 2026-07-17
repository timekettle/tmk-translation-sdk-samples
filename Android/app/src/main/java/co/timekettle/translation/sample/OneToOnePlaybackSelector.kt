package co.timekettle.translation.sample

/**
 * 一对一下行 TTS 播放音源选择器(纯逻辑,可单测)。在线与离线一对一 Demo 共用同一套选路规则,
 * 对齐 iOS 在线/离线共用的 `OneToOneTranslatedAudioPlaybackSelector`。
 *
 * 规则(输出恒为可直接播放的 PCM,并带上其真实声道数):
 * 1. 低延迟单声道帧(`audio_route`=left/right):按本机[播放音源][OneToOnePlaybackMode]只播选中那一路,
 *    对侧丢弃(返回 null)。对齐 iOS「一台设备只听一路」。
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
                return entries.firstOrNull { it.rawValue == value }
            }
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

    /** 立体声交织 PCM 拆分结果(16-bit LE)。 */
    private data class StereoSplit(val left: ByteArray, val right: ByteArray)

    /**
     * 将交织立体声 PCM(16-bit LE)按声道拆分。
     * 仅在 channelCount >= 2 且 data 长度足够时生效;否则返回 null。
     */
    private fun splitStereoInterleaved16LE(data: ByteArray, channelCount: Int): StereoSplit? {
        if (channelCount < 2) return null
        val sampleCount = data.size / (channelCount * 2) // 每采样 2 字节 × 声道数
        if (sampleCount == 0) return null
        val left = ByteArray(sampleCount * 2)
        val right = ByteArray(sampleCount * 2)
        for (i in 0 until sampleCount) {
            val srcBase = i * channelCount * 2
            left[i * 2] = data[srcBase]
            left[i * 2 + 1] = data[srcBase + 1]
            right[i * 2] = data[srcBase + 2]
            right[i * 2 + 1] = data[srcBase + 3]
        }
        return StereoSplit(left, right)
    }

    /**
     * 选择实际要送去播放的 PCM;返回 null 表示该帧不属于本机播放音源(仅低延迟单路帧),应丢弃。
     *
     * @param audioRoute SDK 交付的 `extraData["audio_route"]`;标准模式通常为 null。
     */
    fun selectPlaybackData(
        data: ByteArray,
        channelCount: Int,
        playbackMode: OneToOnePlaybackMode,
        audioRoute: AudioRoute?,
        leftActive: Boolean? = null,
        rightActive: Boolean? = null,
    ): PlaybackOutput? {
        if (data.isEmpty()) return null
        // 低延迟单路帧:按播放音源只播选中一路,对侧丢弃。
        when (audioRoute) {
            AudioRoute.LEFT ->
                return if (playbackMode == OneToOnePlaybackMode.LEFT) PlaybackOutput(data, channelCount) else null
            AudioRoute.RIGHT ->
                return if (playbackMode == OneToOnePlaybackMode.RIGHT) PlaybackOutput(data, channelCount) else null
            AudioRoute.STEREO, null -> Unit
        }
        // 立体声:按播放音源拆一路,输出单声道。
        val split = splitStereoInterleaved16LE(data, channelCount)
        if (split != null) {
            val effectiveMode = when {
                playbackMode == OneToOnePlaybackMode.LEFT && leftActive == false && rightActive == true ->
                    OneToOnePlaybackMode.RIGHT
                playbackMode == OneToOnePlaybackMode.RIGHT && rightActive == false && leftActive == true ->
                    OneToOnePlaybackMode.LEFT
                else -> playbackMode
            }
            val lane = if (effectiveMode == OneToOnePlaybackMode.LEFT) split.left else split.right
            return PlaybackOutput(lane, channelCount = 1)
        }
        // 非立体声:直接播放。
        return PlaybackOutput(data, channelCount)
    }
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
