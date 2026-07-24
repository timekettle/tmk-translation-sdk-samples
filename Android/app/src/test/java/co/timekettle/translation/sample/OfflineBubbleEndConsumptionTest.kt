package co.timekettle.translation.sample

import co.timekettle.translation.model.Result
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 离线 bubbleEnd 的 Demo 消费层单测(设计 §5 OfflineBubbleEndConsumptionTest)。
 *
 * VM 依赖 Android 框架难纯 JVM 跑,故只测 assembler / formatter 层:
 *  - markBubbleEnded 命中纯数字 bubbleId(离线 publicBubbleId 为纯数字串)。
 *  - makeBubbleEndLine 离线场景格式含 [Offline1V1][BubbleEnd] 及 channel。
 */
class OfflineBubbleEndConsumptionTest {

    // 离线 bubbleEnd 事件 Result:sessionId=bubbleId=纯数字 publicBubbleId,extraData 含 channel。
    private fun offlineBubbleEndResult(
        bubbleId: String,
        channel: String,
        traceId: String? = null,
    ): Result<String> {
        val extra = mutableMapOf<String, Any?>(
            "event" to "bubble_end",
            "kind" to "bubble_end",
            "bubble_id" to bubbleId,
            "channel" to channel,
        )
        if (traceId != null) extra["trace_id"] = traceId
        return Result.Builder<String>()
            .setSessionId(bubbleId)
            .setBubbleId(bubbleId)
            .setData("bubble_end")
            .setSrcCode("en-US")
            .setDstCode("zh-CN")
            .setIsLast(true)
            .setExtraData(extra)
            .build()
    }

    @Test
    fun markBubbleEnded_hitsNumericBubbleId() {
        val assembler = DemoConversationBubbleAssembler()
        val bubbleId = "1770000000000123"
        // 先喂入该气泡的一条 ASR final,产生行。
        assembler.consume(
            DemoConversationEvent(
                bubbleId = bubbleId,
                sessionId = bubbleId,
                lane = DemoConversationLane.LEFT,
                stage = DemoConversationStage.ASR,
                isFinal = true,
                text = "hello",
                sourceLangCode = "en-US",
                targetLangCode = "zh-CN",
                chunkId = null,
            )
        )

        val affected = assembler.markBubbleEnded(bubbleId)
        assertEquals(1, affected.size)
        assertEquals(bubbleId, affected.single().bubbleId)
        // 标记后快照中该行 isBubbleEnded=true。
        assertTrue(assembler.snapshot().single { it.bubbleId == bubbleId }.isBubbleEnded)
    }

    @Test
    fun makeBubbleEndLine_offline1v1_containsSceneChannelAndBubbleId() {
        val bubbleId = "1770000000000456"
        val result = offlineBubbleEndResult(bubbleId, channel = "left")

        val line = DemoTmkResultLogFormatter.makeBubbleEndLine("Offline1V1", result, affectedRows = 1)

        assertTrue(line.contains("[Offline1V1][BubbleEnd][TmkResult]"))
        assertTrue(line.contains("channel=left"))
        assertTrue(line.contains("lane=left"))
        assertTrue(line.contains("bubbleId=$bubbleId"))
        assertTrue(line.contains("data=bubble_end"))
        assertTrue(line.contains("isLast=true"))
        assertTrue(line.contains("affectedRows=1"))
    }

    @Test
    fun makeBubbleEndLine_offlineListen_usesChannelOne() {
        val bubbleId = "1770000000000789"
        val result = offlineBubbleEndResult(bubbleId, channel = "1")

        val line = DemoTmkResultLogFormatter.makeBubbleEndLine("OfflineListen", result, affectedRows = 1)

        assertTrue(line.contains("[OfflineListen][BubbleEnd][TmkResult]"))
        assertTrue(line.contains("channel=1"))
        // channel "1" 映射为 left lane。
        assertTrue(line.contains("lane=left"))
    }
}
