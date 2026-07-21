package co.timekettle.translation.sample

import co.timekettle.translation.model.Result

object DemoTmkResultLogFormatter {
    fun makeLine(scene: String, stage: String, result: Result<*>?, isFinal: Boolean): String {
        val extraData = result?.extraData
        return "[$scene][$stage][TmkResult] " +
            "channel=${channel(extraData)} " +
            "lane=${lane(extraData)} " +
            "sessionId=${result?.sessionId.orEmpty()} " +
            "bubbleId=${bubbleId(result)} " +
            "srcCode=${result?.srcCode.orEmpty()} " +
            "dstCode=${result?.dstCode.orEmpty()} " +
            "isLast=${result?.isLast ?: false} " +
            "isFinal=$isFinal " +
            "data=${result?.data?.toString().orEmpty()} " +
            "extraData=${formatExtraData(extraData)}"
    }

    fun makeBubbleEndLine(scene: String, result: Result<*>?, affectedRows: Int): String {
        val extraData = result?.extraData
        return "[$scene][BubbleEnd][TmkResult] " +
            "channel=${channel(extraData)} " +
            "lane=${lane(extraData)} " +
            "sessionId=${result?.sessionId.orEmpty()} " +
            "bubbleId=${bubbleId(result)} " +
            "srcCode=${result?.srcCode.orEmpty()} " +
            "dstCode=${result?.dstCode.orEmpty()} " +
            "isLast=${result?.isLast ?: false} " +
            "data=${result?.data?.toString().orEmpty()} " +
            "affectedRows=$affectedRows " +
            "extraData=${formatExtraData(extraData)}"
    }

    private fun bubbleId(result: Result<*>?): String {
        val extraData = result?.extraData
        return stringExtra(extraData, "bubble_id")
            ?: stringExtra(extraData, "bubbleId")
            ?: result?.bubbleId?.takeIf { it.isNotEmpty() }
            ?: "sid_${result?.sessionId.orEmpty()}"
    }

    private fun channel(extraData: Map<String, Any?>?): String {
        return stringExtra(extraData, "channel") ?: "-"
    }

    private fun lane(extraData: Map<String, Any?>?): String {
        return when (channel(extraData).lowercase()) {
            "left", "1" -> "left"
            "right", "2" -> "right"
            else -> "-"
        }
    }

    private fun formatExtraData(extraData: Map<String, Any?>?): String {
        if (extraData.isNullOrEmpty()) return "{}"
        return extraData.keys.sorted().joinToString(prefix = "{", postfix = "}") { key ->
            "$key=${extraData[key]}"
        }
    }

    private fun stringExtra(extraData: Map<String, Any?>?, key: String): String? {
        val value = extraData?.get(key) ?: return null
        return value.toString().trim().takeIf { it.isNotEmpty() }
    }
}
