package co.timekettle.translation.sample

import co.timekettle.translation.model.Result

/**
 * Demo 层在线网络事件展示策略。
 *
 * SDK 负责判断和上抛通道状态、错误、事件；Demo 只把可恢复的弱网/丢包事件转为非阻塞提示，
 * 不主动停止或重建通道，避免干扰 SDK 内部重连和恢复逻辑。
 */
class DemoOnlineNetworkEventPolicy {
    private var weakNetworkCount = 0
    private var severeNetworkCount = 0
    private var packetLossCount = 0

    fun statusForEvent(eventName: String, args: Any?): String? {
        return when (eventName) {
            "online_network_quality" -> statusForNetworkQuality(extraData(args))
            "online_rtc_stats",
            "online_remote_audio_stats",
            "online_local_audio_stats" -> statusForPacketLoss(extraData(args))
            else -> null
        }
    }

    fun isExpectedServiceUserOffline(eventName: String, args: Any?): Boolean {
        if (eventName != "online_remote_user_offline") return false
        return booleanValue(extraData(args)["is_expected_service_uid"])
    }

    private fun statusForNetworkQuality(extraData: Map<String, Any?>): String? {
        val txQuality = intValue(extraData["tx_quality"])
        val rxQuality = intValue(extraData["rx_quality"])
        val worstQuality = maxOf(txQuality, rxQuality)
        if (worstQuality <= 0) return null

        if (worstQuality >= 6) {
            severeNetworkCount += 1
            weakNetworkCount = 0
            return if (severeNetworkCount >= 2) "网络连接异常，正在恢复..." else null
        }
        severeNetworkCount = 0

        if (worstQuality >= 4) {
            weakNetworkCount += 1
            return if (weakNetworkCount >= 3) "当前网络较差，翻译可能延迟" else null
        }
        if (worstQuality >= 3) {
            weakNetworkCount += 1
            return if (weakNetworkCount >= 3) "当前网络不稳定，翻译可能延迟" else null
        }

        weakNetworkCount = 0
        return null
    }

    private fun statusForPacketLoss(extraData: Map<String, Any?>): String? {
        val packetLoss = maxOf(
            intValue(extraData["tx_packet_loss_rate"]),
            intValue(extraData["rx_packet_loss_rate"]),
            intValue(extraData["audio_loss_rate"])
        )

        if (packetLoss >= 25) {
            packetLossCount += 1
            return if (packetLossCount >= 2) "音频网络丢包严重，正在恢复..." else null
        }
        if (packetLoss >= 10) {
            packetLossCount += 1
            return if (packetLossCount >= 3) "当前音频网络不稳定，翻译可能延迟" else null
        }

        packetLossCount = 0
        return null
    }

    @Suppress("UNCHECKED_CAST")
    private fun extraData(args: Any?): Map<String, Any?> {
        return when (args) {
            is Result<*> -> args.extraData.orEmpty()
            is Map<*, *> -> args as? Map<String, Any?> ?: emptyMap()
            else -> emptyMap()
        }
    }

    private fun intValue(value: Any?): Int {
        return when (value) {
            is Int -> value
            is Long -> value.toInt()
            is Float -> value.toInt()
            is Double -> value.toInt()
            is String -> value.toIntOrNull() ?: 0
            else -> 0
        }
    }

    private fun booleanValue(value: Any?): Boolean {
        return when (value) {
            is Boolean -> value
            is String -> value.equals("true", ignoreCase = true)
            is Number -> value.toInt() != 0
            else -> false
        }
    }
}
