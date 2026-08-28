package co.timekettle.translation.sample

/**
 * Concurrent 页面仅负责把两套一对一气泡快照投影成页面行。
 *
 * 在线和离线各自持有一个 [DemoConversationBubbleAssembler]，结果只进入所属 Runtime 的
 * assembler；bubble/session/chunk 的聚合规则因此与在线一对一、离线一对一完全一致。
 * 这里不创建输入段，两个 Runtime 之间没有显示层关联。
 */
class ConcurrentConversationMapper(
    maxRows: Int = 200,
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
    )

    private data class RowKey(
        val runtime: Runtime,
        val bubbleId: String,
        val lane: Lane,
    )

    private val onlineAssembler = DemoConversationBubbleAssembler(maxRows = maxRows)
    private val offlineAssembler = DemoConversationBubbleAssembler(maxRows = maxRows)
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
        addSnapshots(Runtime.ONLINE, onlineAssembler.snapshot(), current)
        addSnapshots(Runtime.OFFLINE, offlineAssembler.snapshot(), current)

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

    private fun addSnapshots(
        runtime: Runtime,
        snapshots: List<co.timekettle.translation.model.BubbleRowData>,
        target: MutableMap<RowKey, Row>,
    ) {
        snapshots.forEach { snapshot ->
            val lane = when (snapshot.channel.lowercase()) {
                "2", DemoConversationLane.RIGHT.rawValue -> Lane.RIGHT
                else -> Lane.LEFT
            }
            val key = RowKey(runtime, snapshot.bubbleId, lane)
            target[key] = Row(
                id = "${runtime.name.lowercase()}:${snapshot.bubbleId}:${lane.name.lowercase()}",
                bubbleId = snapshot.bubbleId,
                lane = lane,
                runtime = runtime,
                asr = snapshot.sourceText,
                mt = snapshot.translatedText,
            )
        }
    }
}
