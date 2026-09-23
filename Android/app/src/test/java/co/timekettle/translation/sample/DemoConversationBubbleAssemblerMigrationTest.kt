package co.timekettle.translation.sample

import org.junit.Assert.assertEquals
import org.junit.Test

class DemoConversationBubbleAssemblerMigrationTest {
    @Test
    fun sameSessionFinalReplacesPartialAndLocksSegment() {
        val assembler = DemoConversationBubbleAssembler()
        assembler.consume(event("draft", false, "session-a"))
        assembler.consume(event("final", true, "session-a"))

        val rows = assembler.consume(event("late partial", false, "session-a"))

        assertEquals("final", rows.single().sourceText)
    }

    @Test
    fun newSessionSuspendsOldPartialButAcceptsItsFinal() {
        val assembler = DemoConversationBubbleAssembler()
        assembler.consume(event("A draft", false, "session-a"))
        assembler.consume(event("B draft", false, "session-b"))

        val latePartial = assembler.consume(event("A late partial", false, "session-a"))
        val lateFinal = assembler.consume(event("A final", true, "session-a"))

        assertEquals("A draft B draft...", latePartial.single().sourceText)
        assertEquals("A final B draft...", lateFinal.single().sourceText)
    }

    private fun event(text: String, isFinal: Boolean, sessionId: String) = DemoConversationEvent(
        bubbleId = "bubble-1",
        sessionId = sessionId,
        lane = DemoConversationLane.LEFT,
        stage = DemoConversationStage.ASR,
        isFinal = isFinal,
        text = text,
        sourceLangCode = "en-US",
        targetLangCode = "zh-CN",
    )
}
