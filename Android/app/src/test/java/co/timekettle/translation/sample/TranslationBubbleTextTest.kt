package co.timekettle.translation.sample

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import org.junit.Assert.assertEquals
import org.junit.Test

class TranslationBubbleTextTest {
    @Test
    fun rendersCompletionAndHighlightIndependentlyWithoutChangingText() {
        val line = buildSegmentedLine("ASR：", listOf(
            DemoConversationDisplaySegment("draft", setOf("s"), setOf("1"), isFinal = false),
            DemoConversationDisplaySegment("final", setOf("s"), setOf("2"), isHighlighted = true, isFinal = true),
        ), "unused", Color.Black)
        assertEquals("ASR：draftfinal", line.text)
        val draft = line.spanStyles.single { it.start == 4 }
        val final = line.spanStyles.single { it.start == 9 }
        assertEquals(FontWeight.Normal, draft.item.fontWeight)
        assertEquals(Color.Black, draft.item.color)
        assertEquals(FontWeight.Bold, final.item.fontWeight)
        assertEquals(Color(0xFF007AFF), final.item.color)
    }

    @Test
    fun completionAndHighlightCoverEveryCombinationAndIgnoreEmptySegments() {
        for (final in listOf(false, true)) {
            for (highlighted in listOf(false, true)) {
                val line = buildSegmentedLine("MT：", listOf(
                    DemoConversationDisplaySegment("", setOf("empty"), emptySet(), isHighlighted = true, isFinal = true),
                    DemoConversationDisplaySegment("body", setOf("s"), setOf("c"), isHighlighted = highlighted, isFinal = final),
                ), "fallback", Color.Green, preserveSourceText = false)
                assertEquals("MT：body", line.text)
                val body = line.spanStyles.single { it.start == 3 && it.end == 7 }
                assertEquals(if (final) FontWeight.Bold else FontWeight.Normal, body.item.fontWeight)
                assertEquals(if (highlighted) Color(0xFF007AFF) else Color.Green, body.item.color)
                assertEquals(2, line.spanStyles.size)
            }
        }
    }

    @Test
    fun fallbackLabelAndTranslationSeparatorsRemainNormal() {
        val line = buildSegmentedLine("MT：", listOf(
            DemoConversationDisplaySegment("one", setOf("s"), setOf("1"), isFinal = true),
            DemoConversationDisplaySegment("two", setOf("s"), setOf("2"), isFinal = false),
        ), "unused", Color.Green, preserveSourceText = false)
        assertEquals("MT：one two", line.text)
        assertEquals(FontWeight.Normal, line.spanStyles.single { it.start == 0 }.item.fontWeight)
        assertEquals(FontWeight.Normal, line.spanStyles.single { it.start == 6 }.item.fontWeight)
        val fallback = buildSegmentedLine("MT：", emptyList(), "fallback", Color.Green)
        assertEquals("MT：fallback", fallback.text)
        assertEquals(FontWeight.Normal, fallback.spanStyles.last().item.fontWeight)
        val concurrentEmpty = buildSegmentedLine("MT：", emptyList(), "", Color.Green,
            preserveSourceText = false, emptyFallbackText = "")
        assertEquals("MT：", concurrentEmpty.text)
    }
}
