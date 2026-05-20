package co.timekettle.translation.sample

import co.timekettle.translation.model.Result

internal object OnlineRoomEventHelper {
    fun isCloseRoomNotification(eventName: String, args: Any?): Boolean {
        if (eventName != "online_notification" && eventName != "notification") return false
        val extraData = when (args) {
            is Result<*> -> args.extraData
            is Map<*, *> -> args
            else -> null
        } ?: return false

        val kind = extraData.readString("kind")
        val event = extraData.readString("event")
        val eventType = extraData.readString("event_type")
        return kind == "close_room" &&
            (event == "notification" || event == "notify" || eventType == "notification")
    }

    private fun Map<*, *>.readString(key: String): String? {
        return this[key]?.toString()?.lowercase()
    }
}
