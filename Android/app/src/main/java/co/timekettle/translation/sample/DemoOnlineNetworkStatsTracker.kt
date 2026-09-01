package co.timekettle.translation.sample

import co.timekettle.translation.model.Result

/**
 * Demo 侧在线进房丢包快照，对齐时空壶调试面板：
 * - 上丢：online_local_audio_stats.audio_loss_rate（SDK 已映射为 LocalAudioStats.txPacketLossRate）
 * - 下丢：online_remote_audio_stats.audio_loss_rate（RemoteAudioStats.audioLossRate）
 *
 * 不再消费 / 展示 Agora network quality、RTC 通道丢包、下行 L1–L5 分档。
 */
data class DemoOnlineNetworkStatsSnapshot(
    /** 上行丢包率（%），对应时空壶「上丢」 */
    val txLossRate: Int? = null,
    /** 下行丢包率（%），对应时空壶「下丢」 */
    val rxLossRate: Int? = null,
) {
    fun formatLoss(value: Int?): String = if (value == null) "-" else "${value}%"
}

class DemoOnlineNetworkStatsTracker {
    private var snapshot = DemoOnlineNetworkStatsSnapshot()

    fun current(): DemoOnlineNetworkStatsSnapshot = snapshot

    fun reset(): DemoOnlineNetworkStatsSnapshot {
        snapshot = DemoOnlineNetworkStatsSnapshot()
        return snapshot
    }

    fun consume(eventName: String, args: Any?): DemoOnlineNetworkStatsSnapshot? {
        val extra = extraData(args)
        return when (eventName) {
            "online_remote_audio_stats" -> {
                snapshot = snapshot.copy(rxLossRate = intValueOrNull(extra["audio_loss_rate"]))
                snapshot
            }

            "online_local_audio_stats" -> {
                snapshot = snapshot.copy(txLossRate = intValueOrNull(extra["audio_loss_rate"]))
                snapshot
            }

            else -> null
        }
    }

    @Suppress("UNCHECKED_CAST")
    private fun extraData(args: Any?): Map<String, Any?> {
        return when (args) {
            is Result<*> -> args.extraData.orEmpty()
            is Map<*, *> -> args as? Map<String, Any?> ?: emptyMap()
            else -> emptyMap()
        }
    }

    private fun intValueOrNull(value: Any?): Int? {
        if (value == null) return null
        return when (value) {
            is Int -> value
            is Long -> value.toInt()
            is Float -> value.toInt()
            is Double -> value.toInt()
            is String -> value.toIntOrNull()
            else -> null
        }
    }
}
