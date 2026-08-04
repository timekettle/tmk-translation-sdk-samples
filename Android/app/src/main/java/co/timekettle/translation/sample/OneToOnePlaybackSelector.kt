package co.timekettle.translation.sample


/**
 * 一对一下行 TTS 播放音源选择器(纯逻辑,可单测)。在线与离线一对一 Demo 共用同一套选路规则,
 * 对齐 iOS 在线/离线共用的 `OneToOneTranslatedAudioPlaybackSelector`。
 *
 * 规则(输出恒为可直接播放的 PCM,并带上其真实声道数):
 * 1. 低延迟单声道帧(`audio_route`=left/right):在线 Demo 按原始说话侧 `speaker_channel` 选择，
 *    使“左路/右路翻译”与标准模式保持同一语义；对侧丢弃(返回 null)。
 * 2. 立体声(`audio_route`=stereo 或 channelCount>=2 的交织数据):按播放音源拆出对应一路,**输出单声道**。
 * 3. 其余非立体声:直接播放(原样返回,声道数不变)。
 */
/**
 * PCM 帧处理工具（内联实现，对齐 SDK 内部 `PcmFrameToolkit`）。
 */
private object PcmFrameToolkit {
    private const val BYTES_PER_SAMPLE_16LE = 2
    private const val STEREO_FRAME_BYTES = BYTES_PER_SAMPLE_16LE * 2

    fun splitStereoInterleaved16LE(data: ByteArray, channelCount: Int): StereoSplit? {
        if (channelCount != 2 || data.size < STEREO_FRAME_BYTES || data.size % STEREO_FRAME_BYTES != 0) {
            return null
        }
        val halfSize = data.size / 2
        val left = ByteArray(halfSize)
        val right = ByteArray(halfSize)
        var sourceIndex = 0
        var targetIndex = 0
        while (sourceIndex + 3 < data.size) {
            left[targetIndex] = data[sourceIndex]
            left[targetIndex + 1] = data[sourceIndex + 1]
            right[targetIndex] = data[sourceIndex + 2]
            right[targetIndex + 1] = data[sourceIndex + 3]
            sourceIndex += STEREO_FRAME_BYTES
            targetIndex += BYTES_PER_SAMPLE_16LE
        }
        return StereoSplit(left = left, right = right)
    }

    data class StereoSplit(val left: ByteArray, val right: ByteArray) {
        override fun equals(other: Any?): Boolean {
            if (this === other) return true
            if (other !is StereoSplit) return false
            return left.contentEquals(other.left) && right.contentEquals(other.right)
        }
        override fun hashCode(): Int = 31 * left.contentHashCode() + right.contentHashCode()
    }
}

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
     * 解析在线低延迟帧的原始说话侧。
     *
     * 新版 SDK 直接提供 `speaker_channel`;旧版缺失时由最终播放目标 [audioRoute] 取对侧兜底。
     * `audio_route=stereo` 不代表单一说话侧，返回 null。
     */
    fun resolveOnlineSpeakerChannel(audioRoute: AudioRoute?, rawSpeakerChannel: Any?): AudioRoute? {
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
        // 在线低延迟优先按原始说话侧选择，保持与标准 stereo 的左右路语义一致。
        when (speakerChannel) {
            AudioRoute.LEFT ->
                return if (playbackMode == OneToOnePlaybackMode.LEFT) PlaybackOutput(data, channelCount) else null
            AudioRoute.RIGHT ->
                return if (playbackMode == OneToOnePlaybackMode.RIGHT) PlaybackOutput(data, channelCount) else null
            AudioRoute.STEREO, null -> Unit
        }
        // 未提供说话侧时保留原有 route 行为，供离线和旧调用方使用。
        when (audioRoute) {
            AudioRoute.LEFT ->
                return if (playbackMode == OneToOnePlaybackMode.LEFT) PlaybackOutput(data, channelCount) else null
            AudioRoute.RIGHT ->
                return if (playbackMode == OneToOnePlaybackMode.RIGHT) PlaybackOutput(data, channelCount) else null
            AudioRoute.STEREO, null -> Unit
        }
        // 立体声:按播放音源拆一路,输出单声道。
        val split = PcmFrameToolkit.splitStereoInterleaved16LE(data, channelCount)
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
