package co.timekettle.translation.sample

import co.timekettle.translation.*

/**
 * Concurrent 页面仅负责把两套一对一气泡快照投影成页面行。
 *
 * 在线和离线各自持有一个 [DemoConversationBubbleAssembler]，结果只进入所属 Runtime 的
 * assembler；bubble/session/chunk 的聚合规则因此与在线一对一、离线一对一完全一致。
 * 这里不创建输入段，也不读取或比较 speechMarker，两个 Runtime 之间没有显示层关联。
 */
class ConcurrentConversationMapper(
    maxRows: Int = 20,
) {
    enum class Runtime { ONLINE, OFFLINE }
    enum class Kind { ASR, MT }
    enum class Lane { LEFT, RIGHT }

    data class Row(
        /** 供 LazyColumn/UITableView 稳定复用的 Runtime+bubble+声道键。 */
        val id: String,
        val bubbleId: String,
        val lane: Lane,
        val runtime: Runtime,
        val asr: String,
        val mt: String,
        val sourceSegments: List<DemoConversationDisplaySegment> = emptyList(),
        val translatedSegments: List<DemoConversationDisplaySegment> = emptyList(),
    )

    private data class RowKey(
        val runtime: Runtime,
        val bubbleId: String,
        val lane: Lane,
    )

    private var boundedMaxRows = maxRows.coerceIn(
        DemoConversationBubbleAssembler.MIN_MAX_ROWS,
        DemoConversationBubbleAssembler.MAX_MAX_ROWS,
    )
    private val onlineAssembler = DemoConversationBubbleAssembler(maxRows = boundedMaxRows)
    private val offlineAssembler = DemoConversationBubbleAssembler(maxRows = boundedMaxRows,
        translationAssemblyMode = DemoConversationTranslationAssemblyMode.OFFLINE_CUMULATIVE)
    /** 只用于两个独立列表合并成快照，不参与结果匹配。 */
    private val rowOrder = linkedMapOf<RowKey, Long>()
    private var nextOrder = 0L

    /**
     * 将一条 SDK 结果事件投递到所属 Runtime 的独立气泡聚合器。
     * 调用方负责使用与在线/离线一对一相同的 DemoConversationEventAdapter 生成 event。
     */
    fun consume(runtime: Runtime, event: DemoConversationEvent): List<Row> {
        assembler(runtime).consume(event)
        return rows()
    }

    fun rows(): List<Row> {
        val current = linkedMapOf<RowKey, Row>()
        addSnapshots(Runtime.ONLINE, onlineAssembler.snapshotWithSegments(), current)
        addSnapshots(Runtime.OFFLINE, offlineAssembler.snapshotWithSegments(), current)

        current.keys.forEach { key ->
            if (rowOrder.containsKey(key) == false) {
                rowOrder[key] = nextOrder++
            }
        }
        rowOrder.entries.removeIf { it.key !in current }

        return rowOrder.entries
            .sortedBy { it.value }
            .mapNotNull { entry -> current[entry.key] }
    }

    /** 同一设置同时作用于在线和离线 Runtime；两侧各自保留最新 N 个气泡。 */
    fun setMaxRows(maxRows: Int): List<Row> {
        boundedMaxRows = maxRows.coerceIn(
            DemoConversationBubbleAssembler.MIN_MAX_ROWS,
            DemoConversationBubbleAssembler.MAX_MAX_ROWS,
        )
        onlineAssembler.setMaxRows(boundedMaxRows)
        offlineAssembler.setMaxRows(boundedMaxRows)
        return rows()
    }

    fun clear() {
        onlineAssembler.clear()
        offlineAssembler.clear()
        rowOrder.clear()
        nextOrder = 0L
    }

    private fun assembler(runtime: Runtime): DemoConversationBubbleAssembler = when (runtime) {
        Runtime.ONLINE -> onlineAssembler
        Runtime.OFFLINE -> offlineAssembler
    }

    /** 并行页沿用旧 row 文本，只裁去分段里多出的尾省略号与空白，不改变聚合器。 */
    private fun alignTranslatedSegments(
        segments: List<DemoConversationDisplaySegment>,
        displayText: String,
    ): List<DemoConversationDisplaySegment> {
        val textSegments = segments.filter { it.text.isNotEmpty() }
        val segmentedText = textSegments.joinToString(" ") { it.text }
        if (segmentedText == displayText) return textSegments
        // 非前缀差异保守回退 row 原文，保证字体增强不改变旧页面正文。
        if (!segmentedText.startsWith(displayText)) return emptyList()
        var consumedLength = 0
        return textSegments.mapNotNull { segment ->
            val remaining = displayText.length - consumedLength
            consumedLength += segment.text.length + 1
            if (remaining <= 0) null else segment.copy(text = segment.text.take(remaining))
        }
    }

    private fun addSnapshots(
        runtime: Runtime,
        snapshots: List<DemoConversationBubbleSnapshot>,
        target: MutableMap<RowKey, Row>,
    ) {
        snapshots.forEach { snapshot ->
            val row = snapshot.row
            val lane = when (row.channel.lowercase()) {
                "2", DemoConversationLane.RIGHT.rawValue -> Lane.RIGHT
                else -> Lane.LEFT
            }
            val key = RowKey(runtime, row.bubbleId, lane)
            target[key] = Row(
                id = "${runtime.name.lowercase()}:${row.bubbleId}:${lane.name.lowercase()}",
                bubbleId = row.bubbleId,
                lane = lane,
                runtime = runtime,
                asr = row.sourceText,
                mt = row.translatedText,
                sourceSegments = snapshot.sourceSegments,
                translatedSegments = alignTranslatedSegments(snapshot.translatedSegments, row.translatedText),
            )
        }
    }
}
