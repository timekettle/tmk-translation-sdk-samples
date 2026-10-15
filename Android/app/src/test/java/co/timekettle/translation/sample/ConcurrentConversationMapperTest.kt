package co.timekettle.translation.sample

import org.junit.Assert.assertEquals
import org.junit.Test

class ConcurrentConversationMapperTest {
    @Test
    fun historicalTranslationSegmentsPreserveExactLegacyRowTextAndCompletion() {
        for (runtime in ConcurrentConversationMapper.Runtime.entries) {
            for (tail in listOf("draft...", "draft…", "...")) {
                val mapper = ConcurrentConversationMapper()
                mapper.consume(runtime, event(bubbleId = "old", sessionId = "s", lane = DemoConversationLane.LEFT,
                    stage = DemoConversationStage.MT, text = "completed", isFinal = true, chunkId = "1"))
                mapper.consume(runtime, event(bubbleId = "old", sessionId = "s", lane = DemoConversationLane.LEFT,
                    stage = DemoConversationStage.MT, text = tail, isFinal = false, chunkId = "2"))
                mapper.consume(runtime, event(bubbleId = "new", sessionId = "new", lane = DemoConversationLane.LEFT,
                    stage = DemoConversationStage.ASR, text = "new source"))
                val historical = mapper.rows().single { it.bubbleId == "old" }
                assertEquals(if (tail == "...") "completed" else "completed draft", historical.mt)
                assertEquals(historical.mt, historical.translatedSegments.joinToString(" ") { it.text })
                assertEquals(true, historical.translatedSegments.first().isFinal)
                assertEquals(setOf("1"), historical.translatedSegments.first().rawChunkIds)
                if (tail != "...") {
                    assertEquals(false, historical.translatedSegments.last().isFinal)
                    assertEquals(setOf("2"), historical.translatedSegments.last().rawChunkIds)
                }
            }
        }
    }

    @Test
    fun carriesIndependentSegmentCompletionForBothRuntimes() {
        val mapper = ConcurrentConversationMapper()
        for (runtime in ConcurrentConversationMapper.Runtime.entries) {
            mapper.consume(runtime, event(bubbleId = "bubble", sessionId = "s", lane = DemoConversationLane.LEFT,
                stage = DemoConversationStage.ASR, text = "source", isFinal = true))
            mapper.consume(runtime, event(bubbleId = "bubble", sessionId = "s", lane = DemoConversationLane.LEFT,
                stage = DemoConversationStage.MT, text = "translation", isFinal = false, chunkId = "c"))
        }
        mapper.rows().forEach { row ->
            assertEquals(listOf(true), row.sourceSegments.map { it.isFinal })
            assertEquals(listOf(false), row.translatedSegments.map { it.isFinal })
        }
    }

    @Test
    fun offlineRuntimeKeepsRawSourceOrderAndCurrentPartialAfterLateStable() {
        val mapper = ConcurrentConversationMapper()
        fun event(text: String, id: String, final: Boolean) = DemoConversationEvent(
            bubbleId = "b", sessionId = id, lane = DemoConversationLane.LEFT,
            stage = DemoConversationStage.ASR, isFinal = final, text = text,
            sourceLangCode = "en", targetLangCode = "zh")
        mapper.consume(ConcurrentConversationMapper.Runtime.OFFLINE, event(" second draft", "2", false))
        mapper.consume(ConcurrentConversationMapper.Runtime.OFFLINE, event("first.", "1", true))
        val rows = mapper.consume(ConcurrentConversationMapper.Runtime.OFFLINE, event(" second updated", "2", false))
        assertEquals("first. second updated", rows.single().asr)
    }

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
            chunkId = "offline-chunk",
        ))

        val rows = mapper.rows()
        assertEquals(2, rows.size)
        assertEquals("online asr", rows.single { it.runtime == ConcurrentConversationMapper.Runtime.ONLINE }.asr)
        assertEquals("offline mt", rows.single { it.runtime == ConcurrentConversationMapper.Runtime.OFFLINE }.mt)
        assertEquals(setOf("online", "offline"), rows.map { it.runtime.name.lowercase() }.toSet())
    }

    @Test
    fun eachRuntimeUsesTheSameSessionAndChunkAggregationAsOneToOne() {
        val mapper = ConcurrentConversationMapper()
        mapper.consume(ConcurrentConversationMapper.Runtime.OFFLINE, event(
            bubbleId = "offline-bubble",
            sessionId = "session-1",
            lane = DemoConversationLane.LEFT,
            stage = DemoConversationStage.ASR,
            text = "hel",
        ))
        mapper.consume(ConcurrentConversationMapper.Runtime.OFFLINE, event(
            bubbleId = "offline-bubble",
            sessionId = "session-1",
            lane = DemoConversationLane.LEFT,
            stage = DemoConversationStage.ASR,
            text = "hello",
            isFinal = true,
        ))
        mapper.consume(ConcurrentConversationMapper.Runtime.OFFLINE, event(
            bubbleId = "offline-bubble",
            sessionId = "session-1",
            lane = DemoConversationLane.LEFT,
            stage = DemoConversationStage.MT,
            text = "Good morning",
            isFinal = true,
            chunkId = "chunk-1",
        ))
        mapper.consume(ConcurrentConversationMapper.Runtime.OFFLINE, event(
            bubbleId = "offline-bubble",
            sessionId = "session-1",
            lane = DemoConversationLane.LEFT,
            stage = DemoConversationStage.MT,
            text = "See you",
            isFinal = true,
            chunkId = "chunk-2",
        ))

        val row = mapper.rows().single()
        assertEquals("hello", row.asr)
        assertEquals("Good morning See you", row.mt)
    }

    @Test
    fun sameRuntimeKeepsLeftAndRightBubblesSeparate() {
        val mapper = ConcurrentConversationMapper()
        mapper.consume(ConcurrentConversationMapper.Runtime.ONLINE, event(
            bubbleId = "bubble",
            sessionId = "left-session",
            lane = DemoConversationLane.LEFT,
            stage = DemoConversationStage.ASR,
            text = "left",
            isFinal = true,
        ))
        mapper.consume(ConcurrentConversationMapper.Runtime.ONLINE, event(
            bubbleId = "bubble",
            sessionId = "right-session",
            lane = DemoConversationLane.RIGHT,
            stage = DemoConversationStage.ASR,
            text = "right",
            isFinal = true,
        ))

        assertEquals(
            setOf(ConcurrentConversationMapper.Lane.LEFT, ConcurrentConversationMapper.Lane.RIGHT),
            mapper.rows().map { it.lane }.toSet(),
        )
    }

    @Test
    fun mapperDoesNotRequireAnInputBeginOrTraceId() {
        val mapper = ConcurrentConversationMapper()
        mapper.consume(ConcurrentConversationMapper.Runtime.ONLINE, event(
            bubbleId = "server-bubble",
            sessionId = "server-session",
            lane = DemoConversationLane.RIGHT,
            stage = DemoConversationStage.MT,
            text = "server result",
            isFinal = true,
            chunkId = "server-chunk",
        ))

        assertEquals("server result", mapper.rows().single().mt)
    }

    @Test
    fun mapperCapsEachRuntimeSeparatelyAtConfiguredLimit() {
        val mapper = ConcurrentConversationMapper(maxRows = 10)
        for (index in 0..50) {
            val lane = if (index % 2 == 0) DemoConversationLane.LEFT else DemoConversationLane.RIGHT
            mapper.consume(ConcurrentConversationMapper.Runtime.ONLINE, event(
                bubbleId = "online-$index",
                sessionId = "online-session-$index",
                lane = lane,
                stage = DemoConversationStage.ASR,
                text = "online $index",
                isFinal = true,
            ))
            mapper.consume(ConcurrentConversationMapper.Runtime.OFFLINE, event(
                bubbleId = "offline-$index",
                sessionId = "offline-session-$index",
                lane = lane,
                stage = DemoConversationStage.ASR,
                text = "offline $index",
                isFinal = true,
            ))
        }

        val rows = mapper.rows()
        assertEquals(10, rows.count { it.runtime == ConcurrentConversationMapper.Runtime.ONLINE })
        assertEquals(10, rows.count { it.runtime == ConcurrentConversationMapper.Runtime.OFFLINE })
        assertEquals(20, rows.size)
        assertEquals(false, rows.any { it.id == "online:online-0:left" })
        assertEquals(false, rows.any { it.id == "offline:offline-0:left" })
        assertEquals(true, rows.any { it.id == "online:online-50:left" })
        assertEquals(true, rows.any { it.id == "offline:offline-50:left" })
    }

    private fun event(
        bubbleId: String,
        sessionId: String,
        lane: DemoConversationLane,
        stage: DemoConversationStage,
        text: String,
        isFinal: Boolean = false,
        chunkId: String? = null,
    ) = DemoConversationEvent(
        bubbleId = bubbleId,
        sessionId = sessionId,
        lane = lane,
        stage = stage,
        isFinal = isFinal,
        text = text,
        sourceLangCode = "zh-CN",
        targetLangCode = "en-US",
        chunkId = chunkId,
    )
}
