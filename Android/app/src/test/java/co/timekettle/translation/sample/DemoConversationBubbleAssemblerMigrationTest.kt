package co.timekettle.translation.sample

import co.timekettle.translation.model.Result
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class DemoConversationBubbleAssemblerMigrationTest {
    @Test
    fun emptyPartialUpdatesExistingFontWithoutCreatingOrActivatingBubbles() {
        for (mode in DemoConversationTranslationAssemblyMode.entries) {
            val assembler = DemoConversationBubbleAssembler(translationAssemblyMode = mode)
            fun event(bubble: String, chunk: String, text: String, final: Boolean): DemoConversationEvent {
                val result = Result.Builder<String>().setSessionId("session-$chunk").setBubbleId(bubble)
                    .setData(text).setExtraData(mapOf("chunk_id" to chunk, "sentence_state" to "partial")).build()
                return if (mode == DemoConversationTranslationAssemblyMode.OFFLINE_CUMULATIVE)
                    DemoConversationEventAdapter.makeOfflineTranslatedEvent(result, final, "zh", "en")!!
                else DemoConversationEventAdapter.makeTranslatedEvent(result, final, "zh", "en")!!
            }
            assembler.consume(event("old", "1", "locked", true))
            assembler.consume(event("active", "2", "current", false))
            val before = assembler.snapshot()
            assertEquals("current...", before.last().translatedText)
            assembler.consume(event("old", "1", "", false))
            assertEquals(false, assembler.snapshotWithSegments().first().translatedSegments.single().isFinal)
            assertEquals(before, assembler.snapshot())
            assembler.consume(event("old", "missing", "", false))
            assembler.consume(event("unknown", "missing", "", false))
            assertEquals(before, assembler.snapshot())
            assertEquals(1, assembler.snapshotWithSegments().first().translatedSegments.size)
        }
    }

    @Test
    fun rawCompletionFollowsBothDirectionsWithoutUnlockingTextAcrossModesAndStages() {
        for (mode in DemoConversationTranslationAssemblyMode.entries) {
            for (stage in listOf(DemoConversationStage.ASR, DemoConversationStage.MT)) {
                val assembler = DemoConversationBubbleAssembler(translationAssemblyMode = mode)
                fun event(chunk: String, text: String, final: Boolean, bubble: String = "bubble-1"): DemoConversationEvent {
                    val session = if (stage == DemoConversationStage.ASR && mode == DemoConversationTranslationAssemblyMode.CHUNKED)
                        "session-$chunk" else "session"
                    val result = Result.Builder<String>().setSessionId(session).setBubbleId(bubble)
                        .setData(text).setIsLast(!final).setExtraData(mapOf("chunk_id" to chunk,
                            "sentence_state" to if (stage == DemoConversationStage.MT) "stable" else "partial")).build()
                    return when {
                        stage == DemoConversationStage.ASR && mode == DemoConversationTranslationAssemblyMode.OFFLINE_CUMULATIVE ->
                            DemoConversationEventAdapter.makeOfflineRecognizedEvent(result, final, "zh", "en")
                        stage == DemoConversationStage.ASR -> DemoConversationEventAdapter.makeRecognizedEvent(result, final, "zh", "en")
                        mode == DemoConversationTranslationAssemblyMode.OFFLINE_CUMULATIVE ->
                            DemoConversationEventAdapter.makeOfflineTranslatedEvent(result, final, "zh", "en")
                        else -> DemoConversationEventAdapter.makeTranslatedEvent(result, final, "zh", "en")
                    }!!
                }
                fun segments() = assembler.snapshotWithSegments().single().let {
                    if (stage == DemoConversationStage.ASR) it.sourceSegments else it.translatedSegments
                }
                assembler.consume(event("1", "first", false))
                assertEquals(false, segments().single().isFinal)
                assembler.consume(event("1", "first", true))
                assertEquals(true, segments().single().isFinal)
                assembler.consume(event("2", "second", true))
                val lockedText = assembler.snapshot().single().let { if (stage == DemoConversationStage.ASR) it.sourceText else it.translatedText }
                assembler.consume(event("1", "must not replace text", false))
                assertEquals(listOf(false, true), segments().map { it.isFinal })
                assembler.consume(event("1", "must not replace text", true))
                assertEquals(listOf(true, true), segments().map { it.isFinal })
                val beforeEmpty = assembler.snapshot().single()
                assembler.consume(event("1", "", false))
                assertEquals(listOf(false, true), segments().map { it.isFinal })
                assertEquals(beforeEmpty, assembler.snapshot().single())
                assertEquals(lockedText, assembler.snapshot().single().let { if (stage == DemoConversationStage.ASR) it.sourceText else it.translatedText })
                // 空 false 没有已有段可更新时，不创建正文、段或新气泡，也不切换当前气泡。
                assembler.consume(event("missing", "", false))
                assembler.consume(event("missing", "", false, "unknown"))
                assertEquals(beforeEmpty, assembler.snapshot().single())
                assertEquals(2, segments().size)
            }
        }
    }

    @Test
    fun displayCompletionIsIndependentPerStageChunkAndBubbleEnd() {
        val assembler = DemoConversationBubbleAssembler(translationAssemblyMode = DemoConversationTranslationAssemblyMode.OFFLINE_CUMULATIVE)
        assembler.consume(asrEvent("source", false, "session").copy(chunkId = "1"))
        assembler.consume(mtEvent("first", false, "1").copy(sessionId = "session"))
        assembler.consume(mtEvent("second", false, "2").copy(sessionId = "session"))
        assembler.consume(asrEvent("source", true, "session").copy(chunkId = "1"))
        assembler.consume(mtEvent("first", true, "1").copy(sessionId = "session"))
        assembler.markBubbleEnded("bubble-1")
        val snapshot = assembler.snapshotWithSegments().single()
        assertEquals(listOf(true), snapshot.sourceSegments.map { it.isFinal })
        assertEquals(listOf(true, false), snapshot.translatedSegments.map { it.isFinal })
        assembler.consume(asrEvent("ignored source", false, "session").copy(chunkId = "1"))
        val sourceReverted = assembler.snapshotWithSegments().single()
        assertEquals(listOf(false), sourceReverted.sourceSegments.map { it.isFinal })
        assertEquals(listOf(true, false), sourceReverted.translatedSegments.map { it.isFinal })
        assembler.consume(mtEvent("ignored translation", false, "1").copy(sessionId = "session"))
        val translationReverted = assembler.snapshotWithSegments().single()
        assertEquals(listOf(false), translationReverted.sourceSegments.map { it.isFinal })
        assertEquals(listOf(false, false), translationReverted.translatedSegments.map { it.isFinal })
        assertEquals(snapshot.row, translationReverted.row)
    }

    @Test
    fun stableDoesNotBoldButLaterRawFinalRefreshesLockedText() {
        val assembler = DemoConversationBubbleAssembler(translationAssemblyMode = DemoConversationTranslationAssemblyMode.OFFLINE_CUMULATIVE)
        fun event(text: String, final: Boolean, state: String) =
            DemoConversationEventAdapter.makeOfflineTranslatedEvent(Result.Builder<String>()
                .setSessionId("session").setBubbleId("bubble-1").setData(text).setIsLast(true)
                .setExtraData(mapOf("chunk_id" to "chunk", "sentence_state" to state))
                .build(), final, "zh", "en")!!
        assembler.consume(event("locked", false, "stable"))
        val partial = assembler.snapshotWithSegments().single()
        assertEquals(false, partial.translatedSegments.single().isFinal)
        assembler.consume(event("must not replace locked text", true, "partial"))
        val final = assembler.snapshotWithSegments().single()
        assertEquals(partial.row.translatedText, final.row.translatedText)
        assertEquals(true, final.translatedSegments.single().isFinal)
        assembler.consume(event("late draft", false, "stable"))
        assertEquals(false, assembler.snapshotWithSegments().single().translatedSegments.single().isFinal)
    }

    @Test
    fun unchangedSourceTextFinalChangesOnlyDisplayCompletion() {
        val assembler = DemoConversationBubbleAssembler()
        assembler.consume(asrEvent("same", false, "session"))
        val partial = assembler.snapshotWithSegments().single()
        assembler.consume(asrEvent("same", true, "session"))
        val final = assembler.snapshotWithSegments().single()
        assertEquals(partial.row.sourceText, final.row.sourceText)
        assertEquals(false, partial.sourceSegments.single().isFinal)
        assertEquals(true, final.sourceSegments.single().isFinal)
    }

    @Test fun offlineSourceUsesChunksWithinOneSessionAndPreservesEmptyFinalBody() {
        val assembler = DemoConversationBubbleAssembler(translationAssemblyMode = DemoConversationTranslationAssemblyMode.OFFLINE_CUMULATIVE)
        fun source(text: String, final: Boolean, chunk: String): DemoConversationEvent =
            DemoConversationEventAdapter.makeOfflineRecognizedEvent(Result.Builder<String>()
                .setSessionId("same-session").setBubbleId("bubble-1").setData(text)
                .setExtraData(mapOf("chunk_id" to chunk, "sentence_state" to if (final) "stable" else "partial"))
                .build(), final, "zh", "en")!!
        assembler.consume(source("第一句", false, "1"))
        assembler.consume(source("第一句。", true, "1"))
        assembler.consume(source("第二句", false, "2"))
        val rows = assembler.consume(source(" \t\u200B", true, "2"))
        assertEquals("第一句。第二句", rows.single().sourceText)
        assertEquals(listOf(true, true), assembler.snapshotWithSegments().single().sourceSegments.map { it.isFinal })
        // U+001C 不是共同固定空白合同成员，不能按平台 isWhitespace 吞掉原文。
        assertEquals("第一句。第二句\u001C", assembler.consume(source("\u001C", true, "3")).single().sourceText)
    }

    /** 固定 Unicode White_Space 合同不能退回 JVM trim/isWhitespace 的平台集合。 */
    @Test
    fun offlineWhitespaceFinalPreservesEachStageBodyAndZeroWidthSpaceOnlyClosesSource() {
        val whitespace = listOf(
            "\u0009", "\u000A", "\u000B", "\u000C", "\u000D", "\u0020", "\u0085", "\u00A0", "\u1680",
            "\u2000", "\u2001", "\u2002", "\u2003", "\u2004", "\u2005", "\u2006", "\u2007", "\u2008", "\u2009", "\u200A",
            "\u2028", "\u2029", "\u202F", "\u205F", "\u3000",
        )
        for (stage in listOf(DemoConversationStage.ASR, DemoConversationStage.MT)) {
            for (terminal in whitespace + "\u200B") {
                val assembler = DemoConversationBubbleAssembler(
                    translationAssemblyMode = DemoConversationTranslationAssemblyMode.OFFLINE_CUMULATIVE)
                val draft = if (stage == DemoConversationStage.ASR)
                    asrEvent("保留正文", false, "session").copy(chunkId = "1")
                else mtEvent("保留正文", false, "1")
                assembler.consume(draft)
                assembler.consume(draft.copy(text = terminal, isFinal = true, displayIsFinal = true))
                val snapshot = assembler.snapshotWithSegments().single()
                val segments = if (stage == DemoConversationStage.ASR) snapshot.sourceSegments else snapshot.translatedSegments
                val expected = if (stage == DemoConversationStage.MT && terminal == "\u200B") "\u200B" else "保留正文"
                assertEquals("$stage final U+${terminal.single().code.toString(16)}", expected, segments.single().text)
                assertTrue(segments.single().isFinal)
                assertEquals(expected, if (stage == DemoConversationStage.ASR) snapshot.row.sourceText else snapshot.row.translatedText)
                assertFalse("句终态不能代替 BubbleEnd", snapshot.row.isBubbleEnded)
            }
        }
    }

    @Test
    fun offlineNumericSourceOrderKeepsNewerPartialActiveWhenOlderStableArrives() {
        val assembler = DemoConversationBubbleAssembler(translationAssemblyMode = DemoConversationTranslationAssemblyMode.OFFLINE_CUMULATIVE)
        assembler.consume(asrEvent(" second draft", false, "2"))
        assembler.consume(asrEvent("first.", true, "1"))
        val rows = assembler.consume(asrEvent(" second updated", false, "2"))
        assertEquals("first. second updated", rows.single().sourceText)
    }

    @Test
    fun sourceFragmentsPreserveEveryCharacterAndDoNotInventSeparators() {
        val assembler = DemoConversationBubbleAssembler()
        assembler.consume(asrEvent(" \t他说……", true, "1"))
        val rows = assembler.consume(asrEvent("\n然后离开。\u00a0", true, "2"))
        assertEquals(" \t他说……\n然后离开。\u00a0", rows.single().sourceText)
        assertEquals(rows.single().sourceText,
            assembler.snapshotWithSegments().single().sourceSegments.joinToString("") { it.text })
    }

    @Test
    fun sourcePartialContainsOnlyActualAsrCharacters() {
        val assembler = DemoConversationBubbleAssembler()
        assertEquals("原始尾文 ", assembler.consume(asrEvent("原始尾文 ", false, "1")).single().sourceText)
    }

    @Test
    fun recognizedAdapterPreservesRawBoundaryWhitespace() {
        val result = Result.Builder<String>().setSessionId("1").setBubbleId("b")
            .setData("\ttext\n").setSrcCode("en").setDstCode("zh").build()
        assertEquals("\ttext\n", DemoConversationEventAdapter.makeRecognizedEvent(result, true, "en", "zh")?.text)
    }

    @Test
    fun explicitRetractionClearsOnlyItsOwnPartial() {
        val assembler = DemoConversationBubbleAssembler(translationAssemblyMode = DemoConversationTranslationAssemblyMode.OFFLINE_CUMULATIVE)
        assembler.consume(mtEvent("old draft", false, "1"))
        assembler.consume(mtEvent("current", false, "2"))
        val result = Result.Builder<String>().setSessionId("1").setBubbleId("bubble-1")
            .setData("").setSrcCode("zh").setDstCode("en")
            .setExtraData(mapOf("chunk_id" to "1", "sentence_state" to "stable", "text_action" to "retract")).build()
        val event = DemoConversationEventAdapter.makeOfflineTranslatedEvent(result, false, "zh", "en")!!
        val rows = assembler.consume(event)
        assertEquals("current...", rows.single().translatedText)
    }

    @Test
    fun listIdentityKeepsBothLanesWhenPublicSessionAndBubbleIdsMatch() {
        val assembler = DemoConversationBubbleAssembler(translationAssemblyMode = DemoConversationTranslationAssemblyMode.OFFLINE_CUMULATIVE)
        val session = "1791451445070000"
        val bubble = "1791451445070001"
        for (lane in DemoConversationLane.entries) {
            assembler.consume(DemoConversationEvent(bubbleId = bubble, sessionId = session, lane = lane,
                stage = DemoConversationStage.ASR, isFinal = false, text = "source-${lane.rawValue}",
                sourceLangCode = if (lane == DemoConversationLane.LEFT) "en" else "zh",
                targetLangCode = if (lane == DemoConversationLane.LEFT) "zh" else "en"))
        }
        val snapshots = assembler.snapshotWithSegments()
        assertEquals(2, snapshots.size)
        assertEquals(setOf("left", "right"), snapshots.map { it.row.channel }.toSet())
        assertEquals(2, snapshots.map { it.itemKey }.toSet().size)
        assertEquals(setOf("${bubble}_left", "${bubble}_right"), snapshots.map { it.itemKey }.toSet())
        assertTrue(snapshots.first { it.row.channel == "left" }.row.sourceText.contains("source-left"))
        assertTrue(snapshots.first { it.row.channel == "right" }.row.sourceText.contains("source-right"))
    }

    @Test
    fun listIdentityStaysStableAcrossSentencePartialStableHighlightAndEnd() {
        val assembler = DemoConversationBubbleAssembler(translationAssemblyMode = DemoConversationTranslationAssemblyMode.OFFLINE_CUMULATIVE)
        assembler.consume(asrEvent("first", false, "session-1"))
        val first = assembler.snapshotWithSegments().single()
        assembler.consume(asrEvent("second", false, "session-2"))
        assembler.consume(mtEvent("translation", false, "chunk-2").copy(sessionId = "session-2"))
        assembler.consume(mtEvent("translation stable", true, "chunk-2").copy(sessionId = "session-2"))
        assembler.markBubbleEnded("bubble-1")
        val updated = assembler.snapshotWithSegments().single()
        assertEquals("session-2", updated.row.sessionId)
        assertEquals(first.itemKey, updated.itemKey)
        val highlighted = DemoConversationHighlighter.applyHighlight(updated, setOf("session-2"), setOf("chunk-2"))
        assertEquals(updated.itemKey, highlighted.itemKey)
        assertTrue(updated.row.sourceText.contains("first")); assertTrue(updated.row.sourceText.contains("second"))
    }

    @Test
    fun bubbleEndReasonIsRetainedForBorderPresentation() {
        val assembler = DemoConversationBubbleAssembler()
        assembler.consume(asrEvent("source", false, "session-1"))

        val ended = assembler.markBubbleEnded("bubble-1", "length").single()

        assertEquals("length", ended.bubbleEndReason)
    }

    @Test
    fun onlineBubbleEndWithoutReasonKeepsBothLanesUnclassified() {
        val assembler = DemoConversationBubbleAssembler()
        for (lane in DemoConversationLane.entries) {
            assembler.consume(asrEvent("source", false, "session-1").copy(lane = lane))
        }

        val ended = assembler.markBubbleEnded("bubble-1")

        assertEquals(2, ended.size)
        ended.forEach { row ->
            assertTrue(row.isBubbleEnded)
            assertNull(row.bubbleEndReason)
        }
        assembler.snapshotWithSegments().forEach { assertNull(it.row.bubbleEndReason) }
    }

    @Test
    fun explicitNullReasonClearsPreviousClassificationOnRepeatedEnd() {
        val assembler = DemoConversationBubbleAssembler()
        assembler.consume(asrEvent("source", false, "session-1"))
        assembler.markBubbleEnded("bubble-1", "length")

        assertNull(assembler.markBubbleEnded("bubble-1", null).single().bubbleEndReason)
    }

    @Test
    fun offlineBlankReasonStillFallsBackToOther() {
        val assembler = DemoConversationBubbleAssembler()
        assembler.consume(asrEvent("source", false, "session-1"))

        assertEquals("other", assembler.markBubbleEnded("bubble-1", " \t ").single().bubbleEndReason)
    }

    @Test
    fun listIdentityRemainsUniqueDuringInterleavedUpdatesAndHistoryTrimming() {
        val assembler = DemoConversationBubbleAssembler(maxRows = 10,
            translationAssemblyMode = DemoConversationTranslationAssemblyMode.OFFLINE_CUMULATIVE)
        repeat(200) { index ->
            for (lane in DemoConversationLane.entries) {
                assembler.consume(DemoConversationEvent(bubbleId = "bubble_${index / 2}", sessionId = "session_$index",
                    lane = lane, stage = DemoConversationStage.ASR, isFinal = index % 3 == 0,
                    text = "source-${lane.rawValue}-$index", sourceLangCode = "zh", targetLangCode = "en"))
                val snapshots = assembler.snapshotWithSegments()
                assertTrue(snapshots.size <= 10)
                assertEquals(snapshots.size, snapshots.map { it.itemKey }.toSet().size)
                snapshots.forEach { snapshot ->
                    assertEquals("${snapshot.row.bubbleId}_${snapshot.row.channel}", snapshot.itemKey)
                }
            }
        }
        val before = assembler.snapshotWithSegments().associate { it.itemKey to it.row.channel }
        assembler.setMaxRows(10)
        val after = assembler.snapshotWithSegments().associate { it.itemKey to it.row.channel }
        assertEquals(before, after)
        assembler.clear()
        assertTrue(assembler.snapshotWithSegments().isEmpty())
    }

    @Test
    fun offlineAdapter_preservesResultLanguagesAndFallsBackOnlyWhenMissing() {
        val result = Result.Builder<String>().setSessionId("1").setBubbleId("b").setData("text")
            .setSrcCode("ja").setDstCode("de").setExtraData(mapOf("chunk_id" to "1")).build()
        val recognized = DemoConversationEventAdapter.makeOfflineRecognizedEvent(result, false, "zh", "en")!!
        val translated = DemoConversationEventAdapter.makeOfflineTranslatedEvent(result, false, "zh", "en")!!
        assertEquals("ja", recognized.sourceLangCode)
        assertEquals("de", recognized.targetLangCode)
        assertEquals("ja", translated.sourceLangCode)
        assertEquals("de", translated.targetLangCode)
        result.srcCode = ""
        result.dstCode = ""
        val fallback = DemoConversationEventAdapter.makeOfflineTranslatedEvent(result, false, "zh", "en")!!
        assertEquals("zh", fallback.sourceLangCode)
        assertEquals("en", fallback.targetLangCode)
    }

    @Test
    fun offlineAdapter_missingBubbleUsesSessionIdentityButMissingChunkIsRejected() {
        val result = Result.Builder<String>().setSessionId("1").setData("draft")
            .setExtraData(mapOf("chunk_id" to "1")).build()
        val recognized = DemoConversationEventAdapter.makeOfflineRecognizedEvent(result, false, "zh", "en")
        val translated = DemoConversationEventAdapter.makeOfflineTranslatedEvent(result, false, "zh", "en")
        assertEquals("sid_1", recognized?.bubbleId)
        assertEquals("sid_1", translated?.bubbleId)
        result.extraData = emptyMap()
        assertNull(DemoConversationEventAdapter.makeOfflineTranslatedEvent(result, false, "zh", "en"))
        assertNull(DemoConversationEventAdapter.makeRecognizedEvent(result, false, "zh", "en"))
    }

    @Test
    fun offlineAdapter_emptyStablePreservesAndLocksCurrentSentence() {
        val assembler = DemoConversationBubbleAssembler(translationAssemblyMode = DemoConversationTranslationAssemblyMode.OFFLINE_CUMULATIVE)
        fun result(text: String, state: String) = Result.Builder<String>()
            .setSessionId("1").setBubbleId("b").setData(text).setSrcCode("zh").setDstCode("en")
            .setIsLast(false).setExtraData(mapOf("chunk_id" to "1", "sentence_state" to state)).build()
        val partial = DemoConversationEventAdapter.makeOfflineTranslatedEvent(result("draft", "partial"), false, "zh", "en")!!
        assembler.consume(partial)
        val stable = DemoConversationEventAdapter.makeOfflineTranslatedEvent(result("", "stable"), false, "zh", "en")
        assertNotNull(stable)
        assembler.consume(stable!!)
        assertEquals("draft", assembler.consume(partial).single().translatedText)
    }

    @Test
    fun offlineEmptyMtFinal_preservesPartialAndLocksChunk() {
        val assembler = DemoConversationBubbleAssembler(translationAssemblyMode = DemoConversationTranslationAssemblyMode.OFFLINE_CUMULATIVE)
        assembler.consume(mtEvent(text = "draft", isFinal = false, chunkId = "1"))
        assembler.consume(mtEvent(text = "", isFinal = true, chunkId = "1"))
        assembler.consume(mtEvent(text = "late partial", isFinal = false, chunkId = "1"))
        val rows = assembler.consume(mtEvent(text = "late final", isFinal = true, chunkId = "1"))
        assertEquals("draft", rows.singleOrNull()?.translatedText)
    }

    @Test
    fun offlineEmptyAsrFinal_preservesSuspendedPartialWithoutReplacingCurrentSession() {
        val assembler = DemoConversationBubbleAssembler(translationAssemblyMode = DemoConversationTranslationAssemblyMode.OFFLINE_CUMULATIVE)
        assembler.consume(asrEvent(text = "A draft", isFinal = false, sessionId = "1"))
        assembler.consume(asrEvent(text = "B draft", isFinal = false, sessionId = "2"))
        val rows = assembler.consume(asrEvent(text = "", isFinal = true, sessionId = "1"))
        assertEquals("A draftB draft", rows.singleOrNull()?.sourceText)
    }

    @Test
    fun changingMaxRows_trimsOldestImmediatelyAndClampsToSupportedRange() {
        val assembler = DemoConversationBubbleAssembler(maxRows = 20)
        repeat(20) { index ->
            assembler.consume(bubbleMtEvent(
                bubbleId = "bubble-$index",
                text = "$index",
                isFinal = true,
                chunkId = "chunk-$index",
            ))
        }

        val rows = assembler.setMaxRows(10)

        assertEquals(10, rows.size)
        assertEquals("bubble-10", rows.first().bubbleId)
        assertEquals("bubble-19", rows.last().bubbleId)
        assertEquals(10, assembler.setMaxRows(-1).size)
        assertEquals(10, assembler.setMaxRows(999).size)
    }

    @Test
    fun sameChunkId_updatesCurrentTranslationSegment() {
        val assembler = DemoConversationBubbleAssembler()

        assembler.consume(mtEvent(text = "Hello", isFinal = false, chunkId = "chunk-1"))
        val partialRows = assembler.consume(mtEvent(text = "Hello world", isFinal = false, chunkId = "chunk-1"))

        assertEquals(1, partialRows.size)
        assertEquals("Hello world...", partialRows.single().translatedText)

        val finalRows = assembler.consume(mtEvent(text = "Hello world", isFinal = true, chunkId = "chunk-1"))

        assertEquals(1, finalRows.size)
        assertEquals("Hello world", finalRows.single().translatedText)
    }

    /** 空 final 代表当前 chunk 已被撤回，必须清空并固定原先展示的 partial。 */
    @Test
    fun sameChunkId_emptyFinalClearsPartialText() {
        val assembler = DemoConversationBubbleAssembler()

        assembler.consume(mtEvent(text = "Hello world", isFinal = false, chunkId = "chunk-1"))
        val finalRows = assembler.consume(mtEvent(text = "", isFinal = true, chunkId = "chunk-1"))

        assertTrue(finalRows.isEmpty())
        assertTrue(assembler.consume(mtEvent(text = "late partial", isFinal = false, chunkId = "chunk-1")).isEmpty())
    }

    /**
     * Partial 翻译模式回归:同一 chunkId 的中间态(isFinal=false)文本与最终态(isFinal=true)差异较大(非增量)时,
     * final 必须替换该 chunk 上次的中间态,而不是另起新段拼在后面。否则会出现译文重复、"..." 落在中间。
     */
    @Test
    fun sameChunkId_finalReplacesNonIncrementalPartial() {
        val assembler = DemoConversationBubbleAssembler()

        // 中间态猜测
        val partialRows = assembler.consume(mtEvent(text = "I want to go", isFinal = false, chunkId = "chunk-1"))
        assertEquals("I want to go...", partialRows.single().translatedText)

        // 最终态改写了中间态(非增量),同一 chunkId
        val finalRows = assembler.consume(mtEvent(text = "Take me to Beijing", isFinal = true, chunkId = "chunk-1"))

        assertEquals(1, finalRows.size)
        // 只保留最终态,不与中间态重复,且无中间的省略号。
        assertEquals("Take me to Beijing", finalRows.single().translatedText)
    }

    /** 同一 chunkId 首次 final 固定文本，后续任何回调都不得改写。 */
    @Test
    fun sameChunkId_afterFinal_ignoresLaterFinal() {
        val assembler = DemoConversationBubbleAssembler()

        assembler.consume(mtEvent(text = "Hello world", isFinal = true, chunkId = "chunk-1"))
        val rows = assembler.consume(mtEvent(text = "How are you", isFinal = true, chunkId = "chunk-1"))

        assertEquals(1, rows.size)
        assertEquals("Hello world", rows.single().translatedText)
    }

    @Test
    fun mtStableSentenceState_locksChunkBeforeBubbleEnd() {
        val assembler = DemoConversationBubbleAssembler()
        val stableResult = Result.Builder<String>()
            .setSessionId("session-1")
            .setBubbleId("bubble-1")
            .setData("Stable sentence")
            .setSrcCode("en-US")
            .setDstCode("zh-CN")
            .setIsLast(false)
            .setExtraData(
                mapOf(
                    "bubble_id" to "bubble-1",
                    "chunk_id" to "chunk-1",
                    "sentence_state" to "stable",
                )
            )
            .build()

        val stableEvent = DemoConversationEventAdapter.makeTranslatedEvent(stableResult, isFinal = false)
        assertNotNull(stableEvent)
        assembler.consume(stableEvent!!)

        val rows = assembler.consume(mtEvent(text = "late partial", isFinal = false, chunkId = "chunk-1"))

        assertEquals("Stable sentence", rows.single().translatedText)
    }

    @Test
    fun oneToOne_duplicatePartialAndLateStable_updatesOneChunkOnly() {
        val assembler = DemoConversationBubbleAssembler()

        assembler.consume(bubbleMtEvent(
            bubbleId = "bubble-1",
            text = "partial-13",
            isFinal = false,
            chunkId = "13",
            lane = DemoConversationLane.RIGHT,
        ))
        assembler.consume(bubbleMtEvent(
            bubbleId = "bubble-1",
            text = "partial-13",
            isFinal = false,
            chunkId = "13",
            lane = DemoConversationLane.RIGHT,
        ))
        assembler.consume(bubbleMtEvent(
            bubbleId = "bubble-1",
            text = "partial-14",
            isFinal = false,
            chunkId = "14",
            lane = DemoConversationLane.RIGHT,
        ))

        assembler.consume(bubbleMtEvent(
            bubbleId = "bubble-1",
            text = "stable-13",
            isFinal = false,
            chunkId = "13",
            lane = DemoConversationLane.RIGHT,
            isSentenceFinal = true,
        ))
        val rows = assembler.consume(bubbleMtEvent(
            bubbleId = "bubble-1",
            text = "final-14",
            isFinal = true,
            chunkId = "14",
            lane = DemoConversationLane.RIGHT,
        ))

        val row = rows.single()
        assertEquals("stable-13 final-14", row.translatedText)
        assertEquals(2, assembler.snapshotWithSegments().single().translatedSegments.size)
    }

    @Test
    fun sameSession_shorterFinalReplacesPartialThenLocksSegment() {
        val assembler = DemoConversationBubbleAssembler()

        assembler.consume(asrEvent(text = "平均每天都有超过两百个衍生模型出现。我", isFinal = false, sessionId = "session-a"))
        val finalRows = assembler.consume(asrEvent(text = "平均每天都有超过两百个衍生模型出现。", isFinal = true, sessionId = "session-a"))

        assertEquals("平均每天都有超过两百个衍生模型出现。", finalRows.single().sourceText)

        assembler.consume(asrEvent(text = "不应覆盖的 partial", isFinal = false, sessionId = "session-a"))
        val lockedRows = assembler.consume(asrEvent(text = "不应覆盖的 final", isFinal = true, sessionId = "session-a"))

        assertEquals("平均每天都有超过两百个衍生模型出现。", lockedRows.single().sourceText)
    }

    /** final 必须覆盖同一 session 的 partial，即使最终文本为空。 */
    @Test
    fun sameSession_emptyFinalClearsPartialText() {
        val assembler = DemoConversationBubbleAssembler()

        assembler.consume(asrEvent(text = "正在识别的内容", isFinal = false, sessionId = "session-a"))
        val finalRows = assembler.consume(asrEvent(text = "", isFinal = true, sessionId = "session-a"))

        assertTrue(finalRows.isEmpty())
        assertTrue(assembler.consume(asrEvent(text = "迟到 partial", isFinal = false, sessionId = "session-a")).isEmpty())
    }

    @Test
    fun suspendedSession_ignoresLatePartialButAcceptsItsFinal() {
        val assembler = DemoConversationBubbleAssembler()

        assembler.consume(asrEvent(text = "A 初稿", isFinal = false, sessionId = "session-a"))
        assembler.consume(asrEvent(text = "B 初稿", isFinal = false, sessionId = "session-b"))

        val latePartialRows = assembler.consume(asrEvent(text = "A 错误回写", isFinal = false, sessionId = "session-a"))
        assertEquals("A 初稿B 初稿", latePartialRows.single().sourceText)

        val lateFinalRows = assembler.consume(asrEvent(text = "A 最终", isFinal = true, sessionId = "session-a"))
        assertEquals("A 最终B 初稿", lateFinalRows.single().sourceText)
    }

    @Test
    fun suspendedChunk_ignoresLatePartialButAcceptsItsFinal() {
        val assembler = DemoConversationBubbleAssembler()

        assembler.consume(mtEvent(text = "A draft", isFinal = false, chunkId = "chunk-a"))
        assembler.consume(mtEvent(text = "B draft", isFinal = false, chunkId = "chunk-b"))

        val latePartialRows = assembler.consume(mtEvent(text = "A stale", isFinal = false, chunkId = "chunk-a"))
        assertEquals("A draft B draft...", latePartialRows.single().translatedText)

        val lateFinalRows = assembler.consume(mtEvent(text = "A final", isFinal = true, chunkId = "chunk-a"))
        assertEquals("A final B draft...", lateFinalRows.single().translatedText)
    }

    /**
     * Partial 模式多 chunk 交错:两个 chunkId 的中间态穿插到达,各自独立更新中间态,
     * 最终按 chunk 到达顺序拼接、互不污染,不重复。
     */
    @Test
    fun interleavedChunks_updateIndependentlyThenConcatInOrder() {
        val assembler = DemoConversationBubbleAssembler()

        assembler.consume(mtEvent(text = "Good", isFinal = false, chunkId = "chunk-1"))
        assembler.consume(mtEvent(text = "See", isFinal = false, chunkId = "chunk-2"))
        // 各自增量到 final
        assembler.consume(mtEvent(text = "Good morning", isFinal = true, chunkId = "chunk-1"))
        val rows = assembler.consume(mtEvent(text = "See you tomorrow", isFinal = true, chunkId = "chunk-2"))

        assertEquals(1, rows.size)
        assertEquals("Good morning See you tomorrow", rows.single().translatedText)
    }

    @Test
    fun differentChunkIds_appendTranslationSegmentsInOrder() {
        val assembler = DemoConversationBubbleAssembler()

        assembler.consume(mtEvent(text = "Hello world", isFinal = true, chunkId = "chunk-1"))
        val rows = assembler.consume(mtEvent(text = "How are you", isFinal = true, chunkId = "chunk-2"))

        assertEquals(1, rows.size)
        assertEquals("Hello world How are you", rows.single().translatedText)
    }

    @Test
    fun sameBubbleId_keepsLeftAndRightLanesSeparate() {
        val assembler = DemoConversationBubbleAssembler()

        assembler.consume(mtEvent(text = "Left text", isFinal = true, chunkId = "1", lane = DemoConversationLane.LEFT))
        val rows = assembler.consume(mtEvent(text = "Right text", isFinal = true, chunkId = "1", lane = DemoConversationLane.RIGHT))

        assertEquals(2, rows.size)
        assertEquals("left", rows[0].channel)
        assertEquals("Left text", rows[0].translatedText)
        assertEquals("right", rows[1].channel)
        assertEquals("Right text", rows[1].translatedText)
    }

    @Test
    fun markBubbleEnded_marksRowsWithoutBlockingLaterUpdates() {
        val assembler = DemoConversationBubbleAssembler()

        assembler.consume(mtEvent(text = "Hello", isFinal = true, chunkId = "chunk-1"))
        val endedRows = assembler.markBubbleEnded("bubble-1")

        assertEquals(1, endedRows.size)
        assertEquals(true, endedRows.single().isBubbleEnded)

        val updatedRows = assembler.consume(mtEvent(text = "World", isFinal = true, chunkId = "chunk-2"))

        assertEquals("Hello World", updatedRows.single().translatedText)
        assertEquals(true, updatedRows.single().isBubbleEnded)
    }

    /**
     * 端到端:从 SDK Result(extraData 带 offset/duration) 经 makeRecognizedEvent →
     * consume(final) → snapshotWithSegments,验证 bOffset/bDuration 真的透传到 row。
     * 这条覆盖“显示不出来”的排查路径:SDK extraData → 事件 → 聚合 → 快照 → row。
     */
    @Test
    fun endToEnd_asrResultWithOffsetDuration_populatesRowBOffset() {
        val assembler = DemoConversationBubbleAssembler()
        val result = Result.Builder<String>()
            .setSessionId("s1")
            .setBubbleId("bubble-1")
            .setData("我感觉它TTLS很小诶。")
            .setSrcCode("zh-CN")
            .setDstCode("en-US")
            .setIsLast(true)
            .setExtraData(
                mapOf(
                    "bubble_id" to "bubble-1",
                    "channel" to "left",
                    "offset" to 16692000000L,
                    "duration" to 1600000000L,
                )
            )
            .build()

        val event = DemoConversationEventAdapter.makeRecognizedEvent(result, isFinal = true, "zh-CN", "en-US")
        assertNotNull(event)
        assertEquals(16692000000L, event!!.offset)
        assertEquals(1600000000L, event.duration)

        assembler.consume(event)
        val row = assembler.snapshotWithSegments().single().row
        assertEquals(16692000000L, row.bOffset)
        assertEquals(1600000000L, row.bDuration)
    }

    @Test
    fun adapter_extractsBubbleLaneAndChunkFromResultExtraData() {
        val result = Result.Builder<String>()
            .setSessionId("session-1")
            .setData("translated")
            .setSrcCode("en-US")
            .setDstCode("zh-CN")
            .setExtraData(
                mapOf(
                    "bubble_id" to "bubble-1",
                    "channel" to "right",
                    "chunk_id" to 7,
                )
            )
            .build()

        val event = DemoConversationEventAdapter.makeTranslatedEvent(result, isFinal = true)

        assertNotNull(event)
        assertEquals("bubble-1", event!!.bubbleId)
        assertEquals("session-1", event.sessionId)
        assertEquals(DemoConversationLane.RIGHT, event.lane)
        assertEquals("7", event.chunkId)
    }

    // region 必要字段非空校验(bug 7049772181)
    // MT(翻译)要求 bubbleId + sessionId + chunkId 三者非空,任一缺失即丢弃(返回 null)。
    // 根因:服务端 MT partial 曾下发空 chunk_id,与 completed(带 chunk_id)分到不同段导致译文重复。

    @Test
    fun makeTranslatedEvent_chunkIdEmpty_returnsNull() {
        // MT 中间态携带空 chunk_id —— 正是 bug 现场的脏数据形态,应被丢弃。
        val result = Result.Builder<String>()
            .setSessionId("session-1")
            .setData("現在是簡體到繁體")
            .setSrcCode("zh-CN")
            .setDstCode("zh-TW")
            .setExtraData(mapOf("bubble_id" to "bubble-1", "channel" to "right", "chunk_id" to ""))
            .build()

        assertNull(DemoConversationEventAdapter.makeTranslatedEvent(result, isFinal = false))
    }

    @Test
    fun makeTranslatedEvent_noChunkId_returnsNull() {
        // extraData 完全不含 chunk_id —— 同样视为缺失必要字段,丢弃。
        val result = Result.Builder<String>()
            .setSessionId("session-1")
            .setData("translated")
            .setSrcCode("zh-CN")
            .setDstCode("zh-TW")
            .setExtraData(mapOf("bubble_id" to "bubble-1", "channel" to "right"))
            .build()

        assertNull(DemoConversationEventAdapter.makeTranslatedEvent(result, isFinal = true))
    }

    @Test
    fun makeTranslatedEvent_sessionIdEmpty_returnsNull() {
        val result = Result.Builder<String>()
            .setSessionId("")
            .setData("translated")
            .setSrcCode("zh-CN")
            .setDstCode("zh-TW")
            .setExtraData(mapOf("bubble_id" to "bubble-1", "chunk_id" to "chunk-1"))
            .build()

        assertNull(DemoConversationEventAdapter.makeTranslatedEvent(result, isFinal = true))
    }

    @Test
    fun makeTranslatedEvent_bubbleIdEmpty_returnsNull() {
        // 无 bubble_id 且无 result.bubbleId 兜底源 —— rawBubbleId 为 null,丢弃(不用 sid_ 合成掩盖)。
        val result = Result.Builder<String>()
            .setSessionId("session-1")
            .setData("translated")
            .setSrcCode("zh-CN")
            .setDstCode("zh-TW")
            .setExtraData(mapOf("channel" to "right", "chunk_id" to "chunk-1"))
            .build()

        assertNull(DemoConversationEventAdapter.makeTranslatedEvent(result, isFinal = true))
    }

    @Test
    fun makeTranslatedEvent_allPresent_returnsEvent() {
        val result = Result.Builder<String>()
            .setSessionId("session-1")
            .setData("現在是簡體到繁體。")
            .setSrcCode("zh-CN")
            .setDstCode("zh-TW")
            .setExtraData(mapOf("bubble_id" to "bubble-1", "channel" to "right", "chunk_id" to "chunk-74"))
            .build()

        val event = DemoConversationEventAdapter.makeTranslatedEvent(result, isFinal = true)

        assertNotNull(event)
        assertEquals("bubble-1", event!!.bubbleId)
        assertEquals("session-1", event.sessionId)
        assertEquals("chunk-74", event.chunkId)
    }

    @Test
    fun makeTranslatedEvent_finalRedactedPlaceholder_returnsEvent() {
        val result = Result.Builder<String>()
            .setSessionId("session-1")
            .setData("***")
            .setSrcCode("zh-CN")
            .setDstCode("en-US")
            .setExtraData(mapOf("bubble_id" to "bubble-1", "channel" to "left", "chunk_id" to "chunk-19"))
            .build()

        val event = DemoConversationEventAdapter.makeTranslatedEvent(result, isFinal = true)

        assertNotNull(event)
        assertEquals("***", event!!.text)
        val rows = DemoConversationBubbleAssembler().consume(event)
        assertEquals("***", rows.single().translatedText)
    }

    @Test
    fun onlineListenResult_redactedPlaceholderUpdatesExistingBubbleSnapshot() {
        val assembler = DemoConversationBubbleAssembler()
        val asrResult = Result.Builder<String>()
            .setSessionId("1785814977815255000")
            .setBubbleId("1785814982150786000")
            .setData("你知道*****吗？")
            .setSrcCode("zh-CN")
            .setDstCode("en-US")
            .setIsLast(true)
            .setExtraData(
                mapOf(
                    "channel" to "left",
                    "offset" to 48350000000L,
                    "duration" to 1600000000L,
                )
            )
            .build()
        val mtResult = Result.Builder<String>()
            .setSessionId("1785814977815255000")
            .setBubbleId("1785814982150786000")
            .setData("***")
            .setSrcCode("zh-CN")
            .setDstCode("en-US")
            .setIsLast(true)
            .setExtraData(mapOf("channel" to "left", "chunk_id" to "chunk-19"))
            .build()

        val asrEvent = DemoConversationEventAdapter.makeRecognizedEvent(asrResult, isFinal = true, "zh-CN", "en-US")
        val mtEvent = DemoConversationEventAdapter.makeTranslatedEvent(mtResult, isFinal = true, "zh-CN", "en-US")

        assertNotNull(asrEvent)
        assertNotNull(mtEvent)
        assembler.consume(asrEvent!!)
        assembler.consume(mtEvent!!)
        val snapshot = assembler.snapshotWithSegments().single()
        assertEquals("你知道*****吗？", snapshot.row.sourceText)
        assertEquals("***", snapshot.row.translatedText)
        assertEquals("***", snapshot.translatedSegments.single().text)
    }

    @Test
    fun makeRecognizedEvent_noChunkId_stillReturnsEvent() {
        // ASR 服务端恒无 chunk_id,只要 bubbleId + sessionId 齐全就应正常构建,不能被误丢。
        val result = Result.Builder<String>()
            .setSessionId("session-1")
            .setData("现在是简体到繁体。")
            .setSrcCode("zh-CN")
            .setDstCode("zh-TW")
            .setExtraData(mapOf("bubble_id" to "bubble-1", "channel" to "right"))
            .build()

        val event = DemoConversationEventAdapter.makeRecognizedEvent(result, isFinal = true, "zh-CN", "zh-TW")

        assertNotNull(event)
        assertEquals("bubble-1", event!!.bubbleId)
        assertEquals("session-1", event.sessionId)
        assertNull(event.chunkId)
    }

    @Test
    fun makeRecognizedEvent_sessionIdEmpty_returnsNull() {
        val result = Result.Builder<String>()
            .setSessionId("")
            .setData("现在是简体到繁体。")
            .setSrcCode("zh-CN")
            .setDstCode("zh-TW")
            .setExtraData(mapOf("bubble_id" to "bubble-1", "channel" to "right"))
            .build()

        assertNull(DemoConversationEventAdapter.makeRecognizedEvent(result, isFinal = true, "zh-CN", "zh-TW"))
    }
    // endregion

    // region 长文本合并性能修复(bug 7051627151)
    // longestCommonSubstringLength 从二维 dp 改为一维滚动数组,消除超长句(新闻联播可达数百字符)
    // 每次调用分配数 MB IntArray 导致的 GC/主线程停顿。以下用例经由 composeText 的 mergeCumulativeText
    // 间接验证 LCS 语义未变:同一 ASR session 的超长 partial 增量到 final,仍收敛为单段、不重复。

    @Test
    fun longAsrPartial_incrementalToFinal_mergesToSingleSegment() {
        val assembler = DemoConversationBubbleAssembler()
        // 模拟新闻联播式超长句:partial 逐步增长(数百字符),最后 final 为完整句。
        val base = "美好的卡塔尔多哈出席第四届阿拉伯伊朗对话会议时说伊朗无意发展核武器但坚持和平利用核能的合法权利阿拉戈奇还表示中东地区正处于关键阶段需要各方通过对话协商化解分歧维护地区和平稳定"
        assembler.consume(asrEvent(text = base.take(20), isFinal = false, sessionId = "s1"))
        assembler.consume(asrEvent(text = base.take(80), isFinal = false, sessionId = "s1"))
        assembler.consume(asrEvent(text = base.take(160), isFinal = false, sessionId = "s1"))
        val rows = assembler.consume(asrEvent(text = base, isFinal = true, sessionId = "s1"))

        assertEquals(1, rows.size)
        // 增量收敛为完整句单段,不因超长触发异常/超时,也不重复拼接。
        assertEquals(base, rows.single().sourceText)
    }

    @Test
    fun differentChunkIds_keepIdenticalFinalSegmentsInOrder() {
        val assembler = DemoConversationBubbleAssembler()
        // 不同 chunk 的身份独立，即使文本完全相同也必须保留两个分段。
        val longText = "The Israeli army carried out airstrikes in the north of Gaza this morning resulting in fifty six fatalities and over a hundred injuries according to the local health department report"
        assembler.consume(mtEvent(text = longText, isFinal = true, chunkId = "chunk-1"))
        val rows = assembler.consume(mtEvent(text = longText, isFinal = true, chunkId = "chunk-2"))

        assertEquals(1, rows.size)
        assertEquals("$longText $longText", rows.single().translatedText)
    }
    // endregion

    @Test
    fun snapshotWithSegments_splitsTranslationByChunkAndTracksRawIds() {
        val assembler = DemoConversationBubbleAssembler()

        assembler.consume(mtEvent(text = "Hello world", isFinal = true, chunkId = "chunk-1"))
        assembler.consume(mtEvent(text = "How are you", isFinal = true, chunkId = "chunk-2"))
        val snapshots = assembler.snapshotWithSegments()

        assertEquals(1, snapshots.size)
        val segments = snapshots.single().translatedSegments
        assertEquals(2, segments.size)
        assertEquals("Hello world", segments[0].text)
        assertEquals(setOf("chunk-1"), segments[0].rawChunkIds)
        assertEquals("How are you", segments[1].text)
        assertEquals(setOf("chunk-2"), segments[1].rawChunkIds)
    }

    @Test
    fun snapshotWithSegments_appendsEllipsisToActiveNonFinalLastSegment() {
        val assembler = DemoConversationBubbleAssembler()

        assembler.consume(mtEvent(text = "Hello", isFinal = false, chunkId = "chunk-1"))
        val segments = assembler.snapshotWithSegments().single().translatedSegments

        assertEquals(1, segments.size)
        assertEquals("Hello...", segments.single().text)
    }

    @Test
    fun snapshotWithSegments_tracksSourceRawSessionIds() {
        val assembler = DemoConversationBubbleAssembler()

        assembler.consume(asrEvent(text = "Hello", isFinal = true, sessionId = "session-1"))
        val sourceSegments = assembler.snapshotWithSegments().single().sourceSegments

        assertEquals(1, sourceSegments.size)
        assertEquals(setOf("session-1"), sourceSegments.single().rawSessionIds)
    }

    @Test
    fun highlighter_highlightsTranslatedSegmentMatchingBlueChunk() {
        val assembler = DemoConversationBubbleAssembler()
        assembler.consume(mtEvent(text = "Hello world", isFinal = true, chunkId = "chunk-1"))
        assembler.consume(mtEvent(text = "How are you", isFinal = true, chunkId = "chunk-2"))
        val snapshot = assembler.snapshotWithSegments().single()

        val highlighted = DemoConversationHighlighter.applyHighlight(
            snapshot = snapshot,
            blueSessions = emptySet(),
            blueChunks = setOf("chunk-2"),
        )

        assertEquals(false, highlighted.translatedSegments[0].isHighlighted)
        assertEquals(true, highlighted.translatedSegments[1].isHighlighted)
    }

    @Test
    fun highlighter_highlightsSourceSegmentMatchingBlueSession() {
        val assembler = DemoConversationBubbleAssembler()
        assembler.consume(asrEvent(text = "Hello", isFinal = true, sessionId = "session-1"))
        val snapshot = assembler.snapshotWithSegments().single()

        val highlighted = DemoConversationHighlighter.applyHighlight(
            snapshot = snapshot,
            blueSessions = setOf("session-1"),
            blueChunks = emptySet(),
        )

        assertEquals(true, highlighted.sourceSegments.single().isHighlighted)
    }

    @Test
    fun bubbleLangCode_frozenAtCreation_notOverwrittenByLaterSwitch() {
        // 旧气泡在 zh-CN→en-US 下创建,后续事件即便携带新语言(fr-FR→en-US),也应保留原始标签。
        // 复现并锁定 1v1 语言切换 bug:正在进行的旧气泡标签不应跟随全局语言。
        val assembler = DemoConversationBubbleAssembler()

        assembler.consume(
            DemoConversationEvent(
                bubbleId = "bubble-1",
                sessionId = "session-1",
                lane = DemoConversationLane.LEFT,
                stage = DemoConversationStage.MT,
                isFinal = false,
                text = "你好",
                sourceLangCode = "en-US",
                targetLangCode = "zh-CN",
                chunkId = "chunk-1",
            )
        )
        val rows = assembler.consume(
            DemoConversationEvent(
                bubbleId = "bubble-1",
                sessionId = "session-1",
                lane = DemoConversationLane.LEFT,
                stage = DemoConversationStage.MT,
                isFinal = true,
                text = "你好世界",
                sourceLangCode = "en-US",
                targetLangCode = "fr-FR", // 切换后到达的新语言
                chunkId = "chunk-1",
            )
        )

        assertEquals(1, rows.size)
        // 标签保持创建时的 zh-CN,而非被新事件的 fr-FR 覆盖
        assertEquals("zh-CN", rows.single().targetLangCode)
        assertEquals("你好世界", rows.single().translatedText)
    }

    /**
     * 多条 ASR final(不同 offset/duration)进入同一 bubble:
     * bOffset = 第一条 final 的 offset,bDuration = 最后一条 final 的 (offset+duration) − bOffset。
     */
    @Test
    fun asrOffsetDuration_aggregatesFirstOffsetAndLastEnd() {
        val assembler = DemoConversationBubbleAssembler()

        assembler.consume(asrEvent(text = "Hello", isFinal = true, sessionId = "s1", offset = 1000L, duration = 500L))
        assembler.consume(asrEvent(text = "world", isFinal = true, sessionId = "s2", offset = 2000L, duration = 800L))
        val snapshot = assembler.snapshotWithSegments().single()

        assertEquals(1000L, snapshot.bOffset)
        // 最后一条 (2000+800)=2800 − 第一条 offset 1000 = 1800
        assertEquals(1800L, snapshot.bDuration)
        assertEquals(1000L, snapshot.row.bOffset)
        assertEquals(1800L, snapshot.row.bDuration)
    }

    /**
     * partial(非 final)的 ASR 不参与 offset/duration 聚合:
     * 只有 final 句子决定 bOffset / bLastEnd。
     */
    @Test
    fun asrOffsetDuration_ignoresNonFinalPartial() {
        val assembler = DemoConversationBubbleAssembler()

        // partial 携带的 offset 不应被采用
        assembler.consume(asrEvent(text = "Hel", isFinal = false, sessionId = "s1", offset = 100L, duration = 50L))
        assembler.consume(asrEvent(text = "Hello", isFinal = true, sessionId = "s1", offset = 1000L, duration = 500L))
        val snapshot = assembler.snapshotWithSegments().single()

        assertEquals(1000L, snapshot.bOffset)
        assertEquals(500L, snapshot.bDuration)
    }

    /**
     * 服务端不下发 offset/duration(旧版本或非 ASR 场景):
     * SpeechMessage 解析为 null → extraData 不含 offset/duration key →
     * bOffset/bDuration 保持 null → 气泡不显示时间行。
     */
    @Test
    fun `no offset or duration when server omits them`() {
        val assembler = DemoConversationBubbleAssembler()
        // offset/duration 均不传(默认 null)，模拟服务端不下发的情形
        assembler.consume(asrEvent(text = "Hello", isFinal = true, sessionId = "s1"))
        val endedRows = assembler.markBubbleEnded("bubble-1")

        val row = endedRows.single()
        assertNull("服务端未下发 offset 时 bOffset 应为 null，不应显示时间行", row.bOffset)
        assertNull("服务端未下发 duration 时 bDuration 应为 null", row.bDuration)
    }

    private fun mtEvent(
        text: String,
        isFinal: Boolean,
        chunkId: String?,
        lane: DemoConversationLane = DemoConversationLane.LEFT,
    ): DemoConversationEvent {
        return DemoConversationEvent(
            bubbleId = "bubble-1",
            sessionId = "session-1",
            lane = lane,
            stage = DemoConversationStage.MT,
            isFinal = isFinal,
            text = text,
            sourceLangCode = "en-US",
            targetLangCode = "zh-CN",
            chunkId = chunkId,
        )
    }

    /**
     * bug 7051627151:离线旁听长跑退出 demo(OOM)回归。
     * endedBubbleIds 只增不减会随长跑单调增长,trimIfNeeded 淘汰 aggregate 时须同步收敛它。
     * 手法:maxRows=3,喂入并结束 6 个不同 bubble;被淘汰 bubble 的"已结束"标记应随之移除,
     * 仍在容量内的 bubble 保留其 isBubbleEnded=true。
     */
    @Test
    fun trimIfNeeded_evictsEndedBubbleIdsForRemovedAggregates() {
        val assembler = DemoConversationBubbleAssembler(maxRows = 3)
        for (i in 0 until 6) {
            assembler.consume(bubbleMtEvent(bubbleId = "bubble-$i", text = "sentence $i", isFinal = true, chunkId = "chunk-$i"))
            assembler.markBubbleEnded("bubble-$i")
        }
        val rows = assembler.snapshotWithSegments().map { it.row }
        // 仅最后 3 个 bubble 存活。
        assertEquals(3, rows.size)
        assertEquals(setOf("bubble-3", "bubble-4", "bubble-5"), rows.map { it.bubbleId }.toSet())
        // 存活 bubble 的结束标记保留。
        rows.forEach { assertTrue("存活 bubble 应保留 isBubbleEnded", it.isBubbleEnded) }
        // 新 bubble 未结束:若 endedBubbleIds 错误残留历史 id 不影响它,应为 false。
        assembler.consume(bubbleMtEvent(bubbleId = "bubble-6", text = "sentence 6", isFinal = true, chunkId = "chunk-6"))
        val rows2 = assembler.snapshotWithSegments().map { it.row }
        assertEquals(setOf("bubble-4", "bubble-5", "bubble-6"), rows2.map { it.bubbleId }.toSet())
        assertEquals(false, rows2.single { it.bubbleId == "bubble-6" }.isBubbleEnded)
    }

    private fun asrEvent(
        text: String,
        isFinal: Boolean,
        sessionId: String,
        lane: DemoConversationLane = DemoConversationLane.LEFT,
        offset: Long? = null,
        duration: Long? = null,
    ): DemoConversationEvent {
        return DemoConversationEvent(
            bubbleId = "bubble-1",
            sessionId = sessionId,
            lane = lane,
            stage = DemoConversationStage.ASR,
            isFinal = isFinal,
            text = text,
            sourceLangCode = "en-US",
            targetLangCode = "zh-CN",
            chunkId = null,
            offset = offset,
            duration = duration,
        )
    }

    // ---- 快照缓存(修复 A)与超长句(离线收听)回归 ----

    /**
     * 缓存正确性:同一 chunk 的 partial 连续累积成超长文本,每步 snapshotWithSegments 的组装结果
     * 必须与"当前累积文本 + 省略号"一致(缓存命中不得返回过期结果)。回归离线收听单气泡超长 partial。
     */
    @Test
    fun longPartialAccumulation_snapshotStaysConsistentWithCache() {
        val assembler = DemoConversationBubbleAssembler()
        val builder = StringBuilder()
        repeat(60) { i ->
            builder.append("字")
            val text = builder.toString()
            assembler.consume(mtEvent(text = text, isFinal = false, chunkId = "chunk-1"))
            // 每步都取快照(高频刷新场景),活跃气泡非 final 追加省略号。
            val snapshot = assembler.snapshotWithSegments().single()
            assertEquals("$text...", snapshot.row.translatedText)
        }
        // final 收敛后省略号消失,内容为完整累积文本。
        val finalText = builder.toString()
        assembler.consume(mtEvent(text = finalText, isFinal = true, chunkId = "chunk-1"))
        assertEquals(finalText, assembler.snapshotWithSegments().single().row.translatedText)
    }

    /**
     * 缓存跨气泡隔离:气泡 A 已 final(内容冻结)后,气泡 B 持续更新时,重复取快照 A 的组装结果必须稳定不变——
     * 即缓存命中让 A 不被重算,同时不污染 B。验证 contentVersion + isActive 作为缓存键的正确性。
     */
    @Test
    fun endedBubbleResultStableWhileNewBubbleUpdates() {
        val assembler = DemoConversationBubbleAssembler()
        assembler.consume(bubbleMtEvent(bubbleId = "b-A", text = "Alpha done", isFinal = true, chunkId = "ca"))
        // 新气泡 B 多轮 partial 更新。
        var snapA = ""
        repeat(5) { i ->
            assembler.consume(bubbleMtEvent(bubbleId = "b-B", text = "Beta $i", isFinal = false, chunkId = "cb"))
            val snapshots = assembler.snapshotWithSegments()
            val rowA = snapshots.first { it.row.bubbleId == "b-A" }
            snapA = rowA.row.translatedText
            // A 始终是其 final 内容,不受 B 更新影响。
            assertEquals("Alpha done", snapA)
        }
    }

    private fun bubbleMtEvent(
        bubbleId: String,
        text: String,
        isFinal: Boolean,
        chunkId: String?,
        lane: DemoConversationLane = DemoConversationLane.LEFT,
        isSentenceFinal: Boolean = false,
    ): DemoConversationEvent {
        return DemoConversationEvent(
            bubbleId = bubbleId,
            sessionId = "session-$bubbleId",
            lane = lane,
            stage = DemoConversationStage.MT,
            isFinal = isFinal,
            text = text,
            sourceLangCode = "en-US",
            targetLangCode = "zh-CN",
            chunkId = chunkId,
            isSentenceFinal = isSentenceFinal,
        )
    }
}
