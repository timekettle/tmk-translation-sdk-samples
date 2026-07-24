package co.timekettle.translation.sample

import co.timekettle.translation.model.BubbleRowData
import co.timekettle.translation.model.Result
import kotlin.math.max

enum class DemoConversationStage {
    ASR,
    MT,
    TTS,
}

enum class DemoConversationLane(val rawValue: String) {
    LEFT("left"),
    RIGHT("right"),
}

data class DemoConversationEvent(
    val bubbleId: String,
    val sessionId: String,
    val lane: DemoConversationLane,
    val stage: DemoConversationStage,
    val isFinal: Boolean,
    val text: String?,
    val sourceLangCode: String,
    val targetLangCode: String,
    val chunkId: String? = null,
    /** ASR 结果携带的起始偏移(纳秒);MT 不携带,恒为 null。 */
    val offset: Long? = null,
    /** ASR 结果携带的时长(纳秒);MT 不携带,恒为 null。 */
    val duration: Long? = null,
)

/**
 * 气泡内按 session 切分的展示片段。
 *
 * 用于「按 session_id / chunk_id 命中着色」的诉求：每个 session（含合并别名）产出一段独立文字，
 * 记录贡献它的原始 session_id 与 chunk_id，由上层根据 online_tts_state 决定 isHighlighted。
 */
data class DemoConversationDisplaySegment(
    /** 该段的展示文字（已做单段省略号处理）。 */
    val text: String,
    /** 贡献该段的原始服务端 session_id 集合（含别名合并）。 */
    val rawSessionIds: Set<String>,
    /** 贡献该段的原始服务端 chunk_id 集合（译文按 chunk 命中时使用）。 */
    val rawChunkIds: Set<String>,
    /** 是否高亮（蓝色），由 ViewModel 写入。 */
    val isHighlighted: Boolean = false,
)

/**
 * 携带分段信息的气泡快照。
 *
 * 由于 [BubbleRowData] 是 SDK model 不便扩展字段，这里在 Demo 本地包一层，
 * 复用 [BubbleRowData] 承载既有字段，并额外携带源/译文分段供高亮渲染。
 */
data class DemoConversationBubbleSnapshot(
    val row: BubbleRowData,
    /** 源语言按 session 切分的展示片段；离线场景可忽略。 */
    val sourceSegments: List<DemoConversationDisplaySegment>,
    /** 目标语言按 session 切分的展示片段；离线场景可忽略。 */
    val translatedSegments: List<DemoConversationDisplaySegment>,
    /** 气泡内第一条 final ASR 的 offset(纳秒)，无则 null。 */
    val bOffset: Long? = null,
    /** 气泡内 (最后一条 final ASR 的 offset+duration) − bOffset(纳秒)，无则 null。 */
    val bDuration: Long? = null,
)

/** 按 online_tts_state 维护的高亮集合，对快照分段计算 isHighlighted。 */
object DemoConversationHighlighter {
    /**
     * 源文按 session_id 命中、译文按 chunk_id 命中：与对应蓝色集合有交集的片段标记高亮。
     */
    fun applyHighlight(
        snapshot: DemoConversationBubbleSnapshot,
        blueSessions: Set<String>,
        blueChunks: Set<String>,
    ): DemoConversationBubbleSnapshot {
        return snapshot.copy(
            sourceSegments = snapshot.sourceSegments.map { segment ->
                segment.copy(
                    isHighlighted = blueSessions.isNotEmpty() &&
                        segment.rawSessionIds.any { it in blueSessions }
                )
            },
            translatedSegments = snapshot.translatedSegments.map { segment ->
                segment.copy(
                    isHighlighted = blueChunks.isNotEmpty() &&
                        segment.rawChunkIds.any { it in blueChunks }
                )
            },
        )
    }
}

object DemoConversationEventAdapter {
    private const val TAG = "DemoConvEventAdapter"

    fun makeRecognizedEvent(
        result: Result<String>?,
        isFinal: Boolean,
        fallbackSourceLangCode: String,
        fallbackTargetLangCode: String,
    ): DemoConversationEvent? {
        val text = normalized(result?.data)
        if (!isDisplayable(text, isFinal)) return null
        // ASR(识别)必要字段校验:bubbleId + sessionId 不能为空。
        // 注意不校验 chunkId——ASR 结果服务端恒不下发 chunk_id(按 session_id 分段),
        // 若校验 chunkId 会把所有 ASR 数据误丢。缺失即为脏数据,丢弃并打日志。
        val rawBubble = rawBubbleId(result)
        val sessionId = result?.sessionId.orEmpty()
        if (rawBubble.isNullOrEmpty() || sessionId.isEmpty()) {
            android.util.Log.w(
                TAG,
                "丢弃ASR数据: 必要字段为空 bubbleId=$rawBubble sessionId=$sessionId isFinal=$isFinal text=$text"
            )
            return null
        }
        return DemoConversationEvent(
            bubbleId = rawBubble,
            sessionId = sessionId,
            lane = lane(result),
            stage = DemoConversationStage.ASR,
            isFinal = isFinal,
            text = text,
            sourceLangCode = result?.srcCode?.takeIf { it.isNotEmpty() } ?: fallbackSourceLangCode,
            targetLangCode = result?.dstCode?.takeIf { it.isNotEmpty() } ?: fallbackTargetLangCode,
            chunkId = chunkId(result),
            offset = longExtra(result?.extraData, "offset"),
            duration = longExtra(result?.extraData, "duration"),
        )
    }

    fun makeTranslatedEvent(
        result: Result<String>?,
        isFinal: Boolean,
        fallbackSourceLangCode: String,
        fallbackTargetLangCode: String,
    ): DemoConversationEvent? {
        val text = normalized(result?.data)
        if (!isDisplayable(text, isFinal)) return null
        // MT(翻译)必要字段校验:bubbleId + sessionId + chunkId 三者不能为空。
        // 根因(bug 7049772181):服务端 MT 中间态(partial)曾下发空 chunk_id,导致同一句话的
        // partial(按 session_id 归段)与 completed(按 chunk_id 归段)落入不同 effectiveSessionId、
        // 未能覆盖而并排展示,分段渲染拼成重复译文。此处对缺失必要字段的脏数据直接丢弃并打日志,
        // 待服务端修复后 partial 带上稳定 chunk_id,中间态可正常恢复。
        val rawBubble = rawBubbleId(result)
        val sessionId = result?.sessionId.orEmpty()
        val chunk = chunkId(result)
        if (rawBubble.isNullOrEmpty() || sessionId.isEmpty() || chunk.isNullOrEmpty()) {
            android.util.Log.w(
                TAG,
                "丢弃MT数据: 必要字段为空 bubbleId=$rawBubble sessionId=$sessionId chunkId=$chunk isFinal=$isFinal text=$text"
            )
            return null
        }
        return DemoConversationEvent(
            bubbleId = rawBubble,
            sessionId = sessionId,
            lane = lane(result),
            stage = DemoConversationStage.MT,
            isFinal = isFinal,
            text = text,
            sourceLangCode = result?.srcCode?.takeIf { it.isNotEmpty() } ?: fallbackSourceLangCode,
            targetLangCode = result?.dstCode?.takeIf { it.isNotEmpty() } ?: fallbackTargetLangCode,
            chunkId = chunk,
        )
    }

    fun makeTranslatedEvent(result: Result<String>, isFinal: Boolean): DemoConversationEvent? {
        return makeTranslatedEvent(
            result = result,
            isFinal = isFinal,
            fallbackSourceLangCode = result.srcCode.orEmpty(),
            fallbackTargetLangCode = result.dstCode.orEmpty(),
        )
    }

    /**
     * 提取「原始」bubbleId,不做 `sid_<sessionId>` 兜底。
     * 用于必要字段非空校验:服务端未下发 bubble_id 时返回 null,以便上层判定为脏数据丢弃,
     * 而非用 sessionId 合成一个看似有效的 id 掩盖问题。
     */
    private fun rawBubbleId(result: Result<*>?): String? {
        val extraData = result?.extraData
        return stringExtra(extraData, "bubble_id")
            ?: stringExtra(extraData, "bubbleId")
            ?: result?.bubbleId?.takeIf { it.isNotEmpty() }
    }

    private fun lane(result: Result<*>?): DemoConversationLane {
        val channel = stringExtra(result?.extraData, "channel")?.lowercase()
        return if (channel == DemoConversationLane.RIGHT.rawValue || channel == "2") {
            DemoConversationLane.RIGHT
        } else {
            DemoConversationLane.LEFT
        }
    }

    private fun chunkId(result: Result<*>?): String? {
        val extraData = result?.extraData
        return stringExtra(extraData, "chunk_id") ?: stringExtra(extraData, "chunkId")
    }

    private fun stringExtra(extraData: Map<String, Any?>?, key: String): String? {
        val value = extraData?.get(key) ?: return null
        return when (value) {
            is String -> value.trim().takeIf { it.isNotEmpty() }
            is Number -> value.toString()
            else -> value.toString().trim().takeIf { it.isNotEmpty() }
        }
    }

    /** 从 extraData 读 Long(值可能是 Long 或其他 Number),无则 null。用于 ASR 的 offset/duration。 */
    private fun longExtra(extraData: Map<String, Any?>?, key: String): Long? {
        return (extraData?.get(key) as? Number)?.toLong()
    }

    private fun normalized(text: String?): String = text.orEmpty().trim()

    private fun isDisplayable(text: String, isFinal: Boolean): Boolean {
        if (text.isEmpty()) return isFinal
        return text.any { !it.isWhitespace() && !it.isPunctuationOrSymbol() }
    }
}

class DemoConversationBubbleAssembler(private val maxRows: Int = 500) {
    private data class SessionSegment(
        val text: String,
        val isFinal: Boolean,
    )

    private data class BubbleAggregate(
        var sourceLangCode: String,
        var targetLangCode: String,
        val sourceSessionOrder: MutableList<String> = mutableListOf(),
        val translatedSessionOrder: MutableList<String> = mutableListOf(),
        val sourceBySession: MutableMap<String, SessionSegment> = mutableMapOf(),
        val translatedBySession: MutableMap<String, SessionSegment> = mutableMapOf(),
        val sourceSessionAlias: MutableMap<String, String> = mutableMapOf(),
        val translatedSessionAlias: MutableMap<String, String> = mutableMapOf(),
        val sourceChunkAlias: MutableMap<String, String> = mutableMapOf(),
        val translatedChunkAlias: MutableMap<String, String> = mutableMapOf(),
        /** effectiveSessionId -> 贡献它的原始服务端 session_id 集合（用于按 session 着色）。 */
        val sourceRawIdsByEffective: MutableMap<String, MutableSet<String>> = mutableMapOf(),
        val translatedRawIdsByEffective: MutableMap<String, MutableSet<String>> = mutableMapOf(),
        /** effectiveSessionId -> 贡献它的原始服务端 chunk_id 集合（用于按 chunk 着色）。 */
        val sourceRawChunkByEffective: MutableMap<String, MutableSet<String>> = mutableMapOf(),
        val translatedRawChunkByEffective: MutableMap<String, MutableSet<String>> = mutableMapOf(),
        var latestSessionId: String = "",
        /** 第一条 final ASR 的 offset(纳秒),一旦设置不再覆盖。 */
        var bOffset: Long? = null,
        /** 最后一条 final ASR 的 (offset+duration)(纳秒),每条 final 更新为最新。 */
        var bLastEnd: Long? = null,
        /**
         * 内容版本号:每次 consume 改动本 aggregate 时自增,作为快照缓存的失效依据。
         * composeText/composeSegments 含 O(文本长度²) 的 LCS/overlap,新闻联播等超长句(单气泡累积 200+ 字)
         * 下单次成本高;且每次快照要遍历全部气泡(可达数百)。缓存后:未变的历史气泡直接复用上次结果,
         * 每次快照只对本轮真正变更的 1~2 个活跃气泡重算,避免"全量气泡 × O(n²)"随时长放大(bug 卡顿根因)。
         */
        var contentVersion: Long = 0L,
        /** 上次快照缓存:命中条件为 contentVersion 与 isActiveBubble 均未变。 */
        var cachedVersion: Long = -1L,
        var cachedIsActive: Boolean = false,
        var cachedSourceText: String = "",
        var cachedTranslatedText: String = "",
        var cachedSourceSegments: List<DemoConversationDisplaySegment> = emptyList(),
        var cachedTranslatedSegments: List<DemoConversationDisplaySegment> = emptyList(),
    )

    private val lock = Any()
    private val aggregates = linkedMapOf<String, BubbleAggregate>()
    private val activeBubbleIdByLane = mutableMapOf<DemoConversationLane, String>()
    private val endedBubbleIds = mutableSetOf<String>()

    fun reset() = synchronized(lock) {
        aggregates.clear()
        activeBubbleIdByLane.clear()
        endedBubbleIds.clear()
    }

    fun clear() = reset()

    fun consume(event: DemoConversationEvent): List<BubbleRowData> = synchronized(lock) {
        val key = rowKey(event.bubbleId, event.lane)
        activeBubbleIdByLane[event.lane] = event.bubbleId
        val aggregate = aggregates.getOrPut(key) {
            BubbleAggregate(
                sourceLangCode = event.sourceLangCode,
                targetLangCode = event.targetLangCode,
            )
        }
        aggregate.latestSessionId = event.sessionId
        // 语言标签在气泡创建时即冻结,不随后续事件覆盖:
        // 切换语言后,正在进行的旧气泡应保留其原始源/目标语言(译文文本仍是旧语言),
        // 新气泡才使用新语言。覆盖会导致旧气泡标签错误地跟随全局语言(见 1v1 语言切换 bug)。

        // offset/duration 聚合:仅 ASR 且 isFinal 的句子参与。bOffset 取第一条 final(不覆盖),
        // bLastEnd 每条 final 更新为最新的 offset+duration。partial(非 final)不影响。
        if (event.stage == DemoConversationStage.ASR && event.isFinal && event.offset != null) {
            if (aggregate.bOffset == null) aggregate.bOffset = event.offset
            if (event.duration != null) aggregate.bLastEnd = event.offset!! + event.duration!!
        }

        when (event.stage) {
            DemoConversationStage.ASR -> update(
                segmentText = event.text,
                isFinal = event.isFinal,
                sessionId = event.sessionId,
                chunkId = event.chunkId,
                sessionOrder = aggregate.sourceSessionOrder,
                segments = aggregate.sourceBySession,
                sessionAliases = aggregate.sourceSessionAlias,
                chunkAliases = aggregate.sourceChunkAlias,
                rawIdsByEffective = aggregate.sourceRawIdsByEffective,
                rawChunkByEffective = aggregate.sourceRawChunkByEffective,
            )
            DemoConversationStage.MT -> update(
                segmentText = event.text,
                isFinal = event.isFinal,
                sessionId = event.sessionId,
                chunkId = event.chunkId,
                sessionOrder = aggregate.translatedSessionOrder,
                segments = aggregate.translatedBySession,
                sessionAliases = aggregate.translatedSessionAlias,
                chunkAliases = aggregate.translatedChunkAlias,
                rawIdsByEffective = aggregate.translatedRawIdsByEffective,
                rawChunkByEffective = aggregate.translatedRawChunkByEffective,
            )
            DemoConversationStage.TTS -> Unit
        }

        // 本 aggregate 内容已变(source/translated/offset 任一),自增版本使其快照缓存失效。
        aggregate.contentVersion++

        trimIfNeeded()
        snapshotLocked()
    }

    fun snapshot(): List<BubbleRowData> = synchronized(lock) {
        snapshotLocked()
    }

    /** 产出带分段的快照，供按 session/chunk 高亮渲染。 */
    fun snapshotWithSegments(): List<DemoConversationBubbleSnapshot> = synchronized(lock) {
        snapshotWithSegmentsLocked()
    }

    fun markBubbleEnded(bubbleId: String): List<BubbleRowData> = synchronized(lock) {
        val normalized = bubbleId.trim()
        if (normalized.isEmpty()) return emptyList()
        endedBubbleIds.add(normalized)
        snapshotLocked().filter { row ->
            row.bubbleId == normalized || row.originalBubbleId == normalized
        }
    }

    private fun update(
        segmentText: String?,
        isFinal: Boolean,
        sessionId: String,
        chunkId: String?,
        sessionOrder: MutableList<String>,
        segments: MutableMap<String, SessionSegment>,
        sessionAliases: MutableMap<String, String>,
        chunkAliases: MutableMap<String, String>,
        rawIdsByEffective: MutableMap<String, MutableSet<String>>,
        rawChunkByEffective: MutableMap<String, MutableSet<String>>,
    ) {
        val text = segmentText.orEmpty().trim()
        if (text.isEmpty() && !isFinal) return

        val normalizedChunk = normalizedChunkId(chunkId)
        val effectiveSessionId = normalizedChunk?.let { chunkKey ->
            chunkAliases.getOrPut(chunkKey) { nextSyntheticSessionId(segments) }
        } ?: sessionAliases[sessionId] ?: sessionId

        if (!sessionOrder.contains(effectiveSessionId)) {
            sessionOrder.add(effectiveSessionId)
        }

        val old = segments[effectiveSessionId]
        // 仅当已固定(old.isFinal)且新文本非增量时才另起新段(对齐 iOS)。
        // 同一 chunkId 的中间态(old.isFinal=false)收到 final 时不另起新段,而是走下方合并:
        // 用新文本替换上次的中间态,避免 partial 与 final 同时保留导致文本重复、"..." 落在中间。
        //
        // 豁免：新消息是 final 且旧消息也是 final 时，这是服务端对同一 session/chunk 发出的
        // 第二次修正版 completed(如 ASR/MT 二次识别或重算结果)。此时应直接覆盖旧 final 而非另起
        // 新段，否则同一句话会重复展示两次(bug 7049772181)。
        // 注意：chunkId 非空时，effectiveSessionId 由 chunkAliases 分配且唯一，同一 chunkId
        // 的多次 final 仍归同一 effectiveSessionId → 正常覆盖，不会多段。
        val isServerCorrectionFinal = isFinal && old != null && old.isFinal
        val shouldAppendAsNewSegment = !isServerCorrectionFinal &&
            old != null &&
            old.isFinal &&
            text.isNotEmpty() &&
            !isIncrementalTransition(old.text, text)
        if (shouldAppendAsNewSegment) {
            val newSessionId = nextSyntheticSessionId(segments)
            sessionOrder.add(newSessionId)
            segments[newSessionId] = SessionSegment(text = text, isFinal = isFinal)
            sessionAliases[sessionId] = newSessionId
            recordRawIds(rawIdsByEffective, rawChunkByEffective, newSessionId, sessionId, normalizedChunk)
            return
        }

        val mergedText = resolveIncrementalText(old?.text.orEmpty(), text)
        val finalValue = (old?.isFinal ?: false) || isFinal
        segments[effectiveSessionId] = SessionSegment(text = mergedText, isFinal = finalValue)
        sessionAliases[sessionId] = effectiveSessionId
        recordRawIds(rawIdsByEffective, rawChunkByEffective, effectiveSessionId, sessionId, normalizedChunk)
    }

    /** 记录某个 effectiveSessionId 由哪些原始 session_id / chunk_id 贡献，供按 session/chunk 着色。 */
    private fun recordRawIds(
        rawIdsByEffective: MutableMap<String, MutableSet<String>>,
        rawChunkByEffective: MutableMap<String, MutableSet<String>>,
        effectiveSessionId: String,
        sessionId: String,
        normalizedChunk: String?,
    ) {
        if (sessionId.isNotEmpty()) {
            rawIdsByEffective.getOrPut(effectiveSessionId) { mutableSetOf() }.add(sessionId)
        }
        if (normalizedChunk != null) {
            rawChunkByEffective.getOrPut(effectiveSessionId) { mutableSetOf() }.add(normalizedChunk)
        }
    }

    /** 组装结果缓存条目:文本 + 分段一并缓存,两个 snapshot 方法共用。 */
    private class ComposedResult(
        val sourceText: String,
        val translatedText: String,
        val sourceSegments: List<DemoConversationDisplaySegment>,
        val translatedSegments: List<DemoConversationDisplaySegment>,
    )

    /**
     * 取本 aggregate 的组装结果:contentVersion 与 isActiveBubble 均命中缓存则直接复用,
     * 否则重算 composeText/composeSegments(含 O(n²) LCS)并写回缓存。
     * 使"全量气泡 × O(n²)/次"降为"仅变更气泡重算",消除长跑随文本长度平方放大的卡顿。
     */
    private fun resolveComposed(aggregate: BubbleAggregate, isActiveBubble: Boolean): ComposedResult {
        if (aggregate.cachedVersion == aggregate.contentVersion && aggregate.cachedIsActive == isActiveBubble) {
            return ComposedResult(
                aggregate.cachedSourceText,
                aggregate.cachedTranslatedText,
                aggregate.cachedSourceSegments,
                aggregate.cachedTranslatedSegments,
            )
        }
        val sourceText = composeText(aggregate.sourceSessionOrder, aggregate.sourceBySession, isActiveBubble)
        val translatedText = composeText(aggregate.translatedSessionOrder, aggregate.translatedBySession, isActiveBubble)
        val sourceSegments = composeSegments(
            aggregate.sourceSessionOrder,
            aggregate.sourceBySession,
            aggregate.sourceRawIdsByEffective,
            aggregate.sourceRawChunkByEffective,
            isActiveBubble,
        )
        val translatedSegments = composeSegments(
            aggregate.translatedSessionOrder,
            aggregate.translatedBySession,
            aggregate.translatedRawIdsByEffective,
            aggregate.translatedRawChunkByEffective,
            isActiveBubble,
        )
        aggregate.cachedVersion = aggregate.contentVersion
        aggregate.cachedIsActive = isActiveBubble
        aggregate.cachedSourceText = sourceText
        aggregate.cachedTranslatedText = translatedText
        aggregate.cachedSourceSegments = sourceSegments
        aggregate.cachedTranslatedSegments = translatedSegments
        return ComposedResult(sourceText, translatedText, sourceSegments, translatedSegments)
    }

    private fun snapshotLocked(): List<BubbleRowData> {
        return aggregates.mapNotNull { (key, aggregate) ->
            val lane = laneFromRowKey(key)
            val bubbleId = bubbleIdFromRowKey(key)
            val isActiveBubble = activeBubbleIdByLane[lane] == bubbleId
            val composed = resolveComposed(aggregate, isActiveBubble)
            val sourceText = composed.sourceText
            val translatedText = composed.translatedText
            if (sourceText.isEmpty() && translatedText.isEmpty()) {
                null
            } else {
                val bOffset = aggregate.bOffset
                val bDuration = if (bOffset != null && aggregate.bLastEnd != null) {
                    aggregate.bLastEnd!! - bOffset
                } else {
                    null
                }
                BubbleRowData(
                    sessionId = aggregate.latestSessionId,
                    bubbleId = bubbleId,
                    originalBubbleId = bubbleId,
                    channel = lane.rawValue,
                    sourceLangCode = aggregate.sourceLangCode,
                    targetLangCode = aggregate.targetLangCode,
                    sourceText = sourceText,
                    translatedText = translatedText,
                    isBubbleEnded = endedBubbleIds.contains(bubbleId),
                    bOffset = bOffset,
                    bDuration = bDuration,
                )
            }
        }
    }

    private fun snapshotWithSegmentsLocked(): List<DemoConversationBubbleSnapshot> {
        return aggregates.mapNotNull { (key, aggregate) ->
            val lane = laneFromRowKey(key)
            val bubbleId = bubbleIdFromRowKey(key)
            val isActiveBubble = activeBubbleIdByLane[lane] == bubbleId
            val composed = resolveComposed(aggregate, isActiveBubble)
            val sourceText = composed.sourceText
            val translatedText = composed.translatedText
            if (sourceText.isEmpty() && translatedText.isEmpty()) {
                null
            } else {
                val bOffset = aggregate.bOffset
                val bDuration = if (bOffset != null && aggregate.bLastEnd != null) {
                    aggregate.bLastEnd!! - bOffset
                } else {
                    null
                }
                val row = BubbleRowData(
                    sessionId = aggregate.latestSessionId,
                    bubbleId = bubbleId,
                    originalBubbleId = bubbleId,
                    channel = lane.rawValue,
                    sourceLangCode = aggregate.sourceLangCode,
                    targetLangCode = aggregate.targetLangCode,
                    sourceText = sourceText,
                    translatedText = translatedText,
                    isBubbleEnded = endedBubbleIds.contains(bubbleId),
                    bOffset = bOffset,
                    bDuration = bDuration,
                )
                DemoConversationBubbleSnapshot(
                    row = row,
                    sourceSegments = composed.sourceSegments,
                    translatedSegments = composed.translatedSegments,
                    bOffset = bOffset,
                    bDuration = bDuration,
                )
            }
        }
    }

    private fun trimIfNeeded() {
        while (aggregates.size > maxRows) {
            val firstKey = aggregates.keys.firstOrNull() ?: return
            aggregates.remove(firstKey)
            // 同步收敛 endedBubbleIds：被淘汰的 bubbleId 若在 left/right 两 lane 都已无存活 aggregate,
            // 从 endedBubbleIds 移除。否则该集合只增不减(markBubbleEnded 每句都 add,仅 reset 清空),
            // 离线旁听新闻联播长跑(14h 数万句)下单调增长 → 内存耗尽被系统杀(bug 7051627151:退出 demo/回首页)。
            val bubbleId = bubbleIdFromRowKey(firstKey)
            if (aggregates.keys.none { bubbleIdFromRowKey(it) == bubbleId }) {
                endedBubbleIds.remove(bubbleId)
            }
        }
    }

    private fun normalizedChunkId(chunkId: String?): String? {
        return chunkId?.trim()?.takeIf { it.isNotEmpty() }
    }

    private fun composeText(
        order: List<String>,
        segments: Map<String, SessionSegment>,
        isActiveBubble: Boolean,
    ): String {
        val orderedTexts = mutableListOf<String>()
        var latestIsFinal = true
        order.forEach { sessionId ->
            val segment = segments[sessionId] ?: return@forEach
            val text = normalizedDisplayText(segment.text, segment.isFinal)
            if (text.isNotEmpty()) {
                orderedTexts.add(text)
                latestIsFinal = segment.isFinal
            }
        }
        if (orderedTexts.isEmpty()) return ""
        var merged = orderedTexts.first()
        for (idx in 1 until orderedTexts.size) {
            merged = mergeCumulativeText(merged, orderedTexts[idx])
        }
        return if (latestIsFinal || !isActiveBubble) {
            removeTrailingEllipsis(merged)
        } else {
            appendEllipsisIfNeeded(merged)
        }
    }

    /** 按 session 顺序产出独立展示片段（不做跨 session 合并去重），用于按 session/chunk 着色。 */
    private fun composeSegments(
        order: List<String>,
        segments: Map<String, SessionSegment>,
        rawIds: Map<String, Set<String>>,
        rawChunks: Map<String, Set<String>>,
        isActiveBubble: Boolean,
    ): List<DemoConversationDisplaySegment> {
        val result = mutableListOf<DemoConversationDisplaySegment>()
        var latestIsFinal = true
        order.forEach { sessionId ->
            val segment = segments[sessionId] ?: return@forEach
            val normalized = normalizedDisplayText(segment.text, segment.isFinal)
            if (normalized.isEmpty()) return@forEach
            result.add(
                DemoConversationDisplaySegment(
                    text = normalized,
                    rawSessionIds = rawIds[sessionId] ?: setOf(sessionId),
                    rawChunkIds = rawChunks[sessionId].orEmpty(),
                )
            )
            latestIsFinal = segment.isFinal
        }
        if (result.isEmpty()) return emptyList()
        // 活跃气泡的最后一段若未 final，补省略号，与 composeText 行为保持一致。
        if (!latestIsFinal && isActiveBubble) {
            val lastIndex = result.size - 1
            result[lastIndex] = result[lastIndex].copy(text = appendEllipsisIfNeeded(result[lastIndex].text))
        }
        return result
    }

    private fun resolveIncrementalText(old: String, new: String): String {
        val lhs = old.trim()
        val rhs = new.trim()
        if (rhs.isEmpty()) return lhs
        if (lhs.isEmpty()) return rhs
        if (shouldPreferRightInUpdate(lhs, rhs)) return rhs
        if (shouldPreferLeftInUpdate(lhs, rhs)) return lhs
        return rhs
    }

    private fun mergeCumulativeText(lhsRaw: String, rhsRaw: String): String {
        val lhs = lhsRaw.trim()
        val rhs = rhsRaw.trim()
        if (lhs.isEmpty()) return rhs
        if (rhs.isEmpty()) return lhs
        if (shouldPreferRightInMerge(lhs, rhs)) return rhs
        if (shouldPreferLeftInMerge(lhs, rhs)) return lhs
        val overlap = longestOverlap(lhs, rhs)
        if (overlap > 0) return lhs + rhs.drop(overlap)
        val similarity = normalizedSimilarity(lhs, rhs)
        if (similarity >= 0.78) return if (rhs.length >= lhs.length) rhs else lhs
        return "$lhs $rhs"
    }

    private fun longestOverlap(lhs: String, rhs: String): Int {
        // 求 lhs 后缀与 rhs 前缀的最长重叠。原实现每个 count 都 takeLast/take 建子串再 == 比较,
        // 是 O(n²) 且产生大量临时字符串;新闻联播等超长句(单气泡 200+ 字)下高频调用会剧烈拖慢。
        // 改用 regionMatches 逐位比较,不分配子串,复杂度与原来同阶但常数与 GC 大幅降低。
        val maxCount = minOf(lhs.length, rhs.length)
        for (count in maxCount downTo 1) {
            if (lhs.regionMatches(lhs.length - count, rhs, 0, count)) return count
        }
        return 0
    }

    private fun appendEllipsisIfNeeded(text: String): String {
        return if (text.endsWith("...") || text.endsWith("…")) text else "$text..."
    }

    private fun normalizedDisplayText(text: String, isFinal: Boolean): String {
        val normalized = text.trim()
        return if (isFinal) removeTrailingEllipsis(normalized) else normalized
    }

    private fun removeTrailingEllipsis(text: String): String {
        var normalized = text.trim()
        while (normalized.endsWith("...") || normalized.endsWith("…")) {
            normalized = if (normalized.endsWith("...")) {
                normalized.dropLast(3)
            } else {
                normalized.dropLast(1)
            }.trim()
        }
        return normalized
    }

    private fun isIncrementalTransition(old: String, new: String): Boolean {
        val lhs = old.trim()
        val rhs = new.trim()
        if (lhs.isEmpty() || rhs.isEmpty()) return false
        if (shouldPreferRightInUpdate(lhs, rhs)) return true
        if (shouldPreferLeftInUpdate(lhs, rhs)) return true
        return normalizedSimilarity(lhs, rhs) >= 0.70
    }

    private fun nextSyntheticSessionId(segments: Map<String, SessionSegment>): String {
        var id = -1
        while (segments.containsKey(id.toString())) {
            id -= 1
        }
        return id.toString()
    }

    private fun shouldPreferRightInUpdate(lhs: String, rhs: String): Boolean {
        if (lhs == rhs) return true
        if (rhs.startsWith(lhs) || rhs.contains(lhs)) return true
        val lhsKey = normalizeCompareKey(lhs)
        val rhsKey = normalizeCompareKey(rhs)
        if (lhsKey.isEmpty() || rhsKey.isEmpty()) return false
        if (rhsKey == lhsKey) return true
        if (rhsKey.startsWith(lhsKey) || rhsKey.contains(lhsKey)) return true
        return normalizedSimilarity(lhs, rhs) >= 0.88 && rhs.length >= lhs.length
    }

    private fun shouldPreferLeftInUpdate(lhs: String, rhs: String): Boolean {
        if (lhs.startsWith(rhs) || lhs.contains(rhs)) return true
        val lhsKey = normalizeCompareKey(lhs)
        val rhsKey = normalizeCompareKey(rhs)
        if (lhsKey.isEmpty() || rhsKey.isEmpty()) return false
        if (lhsKey.startsWith(rhsKey) || lhsKey.contains(rhsKey)) return true
        return normalizedSimilarity(lhs, rhs) >= 0.88 && lhs.length > rhs.length
    }

    private fun shouldPreferRightInMerge(lhs: String, rhs: String): Boolean {
        if (lhs == rhs) return false
        if (rhs.startsWith(lhs) || rhs.contains(lhs)) return true
        val lhsKey = normalizeCompareKey(lhs)
        val rhsKey = normalizeCompareKey(rhs)
        if (lhsKey.isEmpty() || rhsKey.isEmpty()) return false
        if (rhsKey == lhsKey) return rhs.length >= lhs.length
        return rhsKey.startsWith(lhsKey) || rhsKey.contains(lhsKey)
    }

    private fun shouldPreferLeftInMerge(lhs: String, rhs: String): Boolean {
        if (lhs.startsWith(rhs) || lhs.contains(rhs)) return true
        val lhsKey = normalizeCompareKey(lhs)
        val rhsKey = normalizeCompareKey(rhs)
        if (lhsKey.isEmpty() || rhsKey.isEmpty()) return false
        if (lhsKey == rhsKey) return lhs.length > rhs.length
        return lhsKey.startsWith(rhsKey) || lhsKey.contains(rhsKey)
    }

    private fun normalizeCompareKey(text: String): String {
        return text.filter { !it.isWhitespace() && !it.isPunctuationOrSymbol() }.lowercase()
    }

    private fun normalizedSimilarity(lhs: String, rhs: String): Double {
        val lhsKey = normalizeCompareKey(lhs)
        val rhsKey = normalizeCompareKey(rhs)
        if (lhsKey.isEmpty() || rhsKey.isEmpty()) return 0.0
        val common = longestCommonSubstringLength(lhsKey, rhsKey)
        val denominator = max(lhsKey.length, rhsKey.length)
        return if (denominator > 0) common.toDouble() / denominator.toDouble() else 0.0
    }

    private fun longestCommonSubstringLength(lhs: String, rhs: String): Int {
        if (lhs.isEmpty() || rhs.isEmpty()) return 0
        // 用一维滚动数组替代原二维 dp:原实现每次分配 (n+1)×(m+1) 的 IntArray,
        // 新闻联播等超长句(实测单句归一后可达数百字符)会一次性分配数十万 int(数 MB),
        // 长时间高频调用(旁听每秒数次、每次遍历数百气泡)造成剧烈 GC 与主线程停顿(bug 7051627151)。
        // 一维数组把空间从 O(n×m) 降到 O(m);dp[i][j] 依赖左上角 dp[i-1][j-1],
        // 故内层 j 从大到小遍历,dp[j-1] 在被覆盖前仍是上一行(i-1)的值,结果与二维实现完全等价。
        // 让 rhs 作为较短串以最小化数组长度。
        val a: String
        val b: String
        if (lhs.length >= rhs.length) {
            a = lhs; b = rhs
        } else {
            a = rhs; b = lhs
        }
        val dp = IntArray(b.length + 1)
        var best = 0
        for (i in 1..a.length) {
            for (j in b.length downTo 1) {
                dp[j] = if (a[i - 1] == b[j - 1]) dp[j - 1] + 1 else 0
                if (dp[j] > best) best = dp[j]
            }
        }
        return best
    }

    companion object {
        fun rowKey(bubbleId: String, lane: DemoConversationLane): String = "${bubbleId}_${lane.rawValue}"

        private fun bubbleIdFromRowKey(key: String): String = key.substringBeforeLast("_")

        private fun laneFromRowKey(key: String): DemoConversationLane {
            return if (key.substringAfterLast("_") == DemoConversationLane.RIGHT.rawValue) {
                DemoConversationLane.RIGHT
            } else {
                DemoConversationLane.LEFT
            }
        }
    }
}

private fun Char.isPunctuationOrSymbol(): Boolean {
    return when (Character.getType(this)) {
        Character.CONNECTOR_PUNCTUATION.toInt(),
        Character.DASH_PUNCTUATION.toInt(),
        Character.START_PUNCTUATION.toInt(),
        Character.END_PUNCTUATION.toInt(),
        Character.INITIAL_QUOTE_PUNCTUATION.toInt(),
        Character.FINAL_QUOTE_PUNCTUATION.toInt(),
        Character.OTHER_PUNCTUATION.toInt(),
        Character.MATH_SYMBOL.toInt(),
        Character.CURRENCY_SYMBOL.toInt(),
        Character.MODIFIER_SYMBOL.toInt(),
        Character.OTHER_SYMBOL.toInt() -> true
        else -> false
    }
}
