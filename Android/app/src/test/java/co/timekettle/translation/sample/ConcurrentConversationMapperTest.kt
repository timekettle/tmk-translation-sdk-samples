package co.timekettle.translation.sample

import org.junit.Assert.assertEquals
import org.junit.Test

class ConcurrentConversationMapperTest {
    @Test
    fun sameBubbleIdAcrossRuntimes_isRenderedAsTwoIndependentRows() {
        val mapper = ConcurrentConversationMapper()
        mapper.consume(ConcurrentConversationMapper.Runtime.ONLINE, event(
            bubbleId = "same-bubble",
            sessionId = "online-session",
            lane = DemoConversationLane.RIGHT,
            stage = DemoConversationStage.ASR,
            text = "online asr",
            isFinal = true,
        ))
        mapper.consume(ConcurrentConversationMapper.Runtime.OFFLINE, event(
            bubbleId = "same-bubble",
            sessionId = "offline-session",
            lane = DemoConversationLane.RIGHT,
            stage = DemoConversationStage.MT,
            text = "offline mt",
            isFinal = true,
        ))

        val rows = mapper.rows()
        assertEquals(2, rows.size)
        assertEquals("online asr", rows.single { it.runtime == ConcurrentConversationMapper.Runtime.ONLINE }.asr)
        assertEquals("offline mt", rows.single { it.runtime == ConcurrentConversationMapper.Runtime.OFFLINE }.mt)
    }

    private fun event(
        bubbleId: String,
        sessionId: String,
        lane: DemoConversationLane,
        stage: DemoConversationStage,
        text: String,
        isFinal: Boolean = false,
    ) = DemoConversationEvent(
        bubbleId = bubbleId,
        sessionId = sessionId,
        lane = lane,
        stage = stage,
        isFinal = isFinal,
        text = text,
        sourceLangCode = "zh-CN",
        targetLangCode = "en-US",
    )
}
