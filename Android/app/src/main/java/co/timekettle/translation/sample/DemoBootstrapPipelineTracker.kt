package co.timekettle.translation.sample

/**
 * Demo 侧进房 bootstrap 链路：鉴权 → 建房 → 建通道 → 通道就绪。
 * 段耗时与总耗时均由宿主本地打点，不依赖 SDK 额外 API。
 */
enum class DemoBootstrapStage {
    AUTH,
    CREATE_ROOM,
    CREATE_CHANNEL,
    CHANNEL_READY,
    ;

    val label: String
        get() = when (this) {
            AUTH -> "鉴权"
            CREATE_ROOM -> "建房"
            CREATE_CHANNEL -> "建通道"
            CHANNEL_READY -> "就绪"
        }
}

enum class DemoBootstrapNodeStatus {
    PENDING,
    RUNNING,
    DONE,
    FAILED,
}

data class DemoBootstrapNodeSnapshot(
    val stage: DemoBootstrapStage,
    val status: DemoBootstrapNodeStatus = DemoBootstrapNodeStatus.PENDING,
    /** DONE/FAILED 为段耗时；RUNNING 由 UI 用 startedAtMs 实时算 */
    val durationMs: Long? = null,
    val startedAtMs: Long? = null,
)

data class DemoBootstrapSnapshot(
    val nodes: List<DemoBootstrapNodeSnapshot> = DemoBootstrapStage.entries.map {
        DemoBootstrapNodeSnapshot(it)
    },
    /** 从鉴权开始到通道就绪的总耗时；未完成则为 null */
    val totalMs: Long? = null,
    val startedAtMs: Long? = null,
    val completedAtMs: Long? = null,
    val failed: Boolean = false,
) {
    val isRunning: Boolean
        get() = !failed && totalMs == null && nodes.any { it.status == DemoBootstrapNodeStatus.RUNNING }

    fun formatDuration(ms: Long?): String = when {
        ms == null -> "-"
        ms < 1000 -> "${ms}ms"
        else -> String.format("%.1fs", ms / 1000.0)
    }

    fun nodeLine(node: DemoBootstrapNodeSnapshot, nowMs: Long = System.currentTimeMillis()): String {
        val elapsed = when (node.status) {
            DemoBootstrapNodeStatus.RUNNING ->
                node.startedAtMs?.let { (nowMs - it).coerceAtLeast(0L) }
            DemoBootstrapNodeStatus.DONE,
            DemoBootstrapNodeStatus.FAILED -> node.durationMs
            DemoBootstrapNodeStatus.PENDING -> null
        }
        val mark = when (node.status) {
            DemoBootstrapNodeStatus.PENDING -> "·"
            DemoBootstrapNodeStatus.RUNNING -> "…"
            DemoBootstrapNodeStatus.DONE -> "✓"
            DemoBootstrapNodeStatus.FAILED -> "✗"
        }
        return "${node.stage.label}$mark ${formatDuration(elapsed)}"
    }

    fun summaryLine(nowMs: Long = System.currentTimeMillis()): String {
        return nodes.joinToString("  ") { nodeLine(it, nowMs) }
    }

    fun totalLine(nowMs: Long = System.currentTimeMillis()): String {
        val ms = when {
            totalMs != null -> totalMs
            startedAtMs != null && (isRunning || failed) ->
                (nowMs - startedAtMs).coerceAtLeast(0L)
            else -> null
        }
        val suffix = when {
            failed -> "失败"
            totalMs != null -> "完成"
            isRunning -> "进行中"
            else -> ""
        }
        return if (suffix.isEmpty()) {
            "Bootstrap ${formatDuration(ms)}"
        } else {
            "Bootstrap $suffix ${formatDuration(ms)}"
        }
    }
}

class DemoBootstrapPipelineTracker {
    private var snapshot = DemoBootstrapSnapshot()

    fun current(): DemoBootstrapSnapshot = snapshot

    fun reset(): DemoBootstrapSnapshot {
        snapshot = DemoBootstrapSnapshot()
        return snapshot
    }

    fun begin(stage: DemoBootstrapStage, nowMs: Long = System.currentTimeMillis()): DemoBootstrapSnapshot {
        if (stage == DemoBootstrapStage.AUTH) {
            snapshot = DemoBootstrapSnapshot(
                startedAtMs = nowMs,
                nodes = DemoBootstrapStage.entries.map { s ->
                    if (s == DemoBootstrapStage.AUTH) {
                        DemoBootstrapNodeSnapshot(
                            stage = s,
                            status = DemoBootstrapNodeStatus.RUNNING,
                            startedAtMs = nowMs,
                        )
                    } else {
                        DemoBootstrapNodeSnapshot(s)
                    }
                },
            )
            return snapshot
        }

        val nodes = snapshot.nodes.map { node ->
            when {
                node.stage == stage -> node.copy(
                    status = DemoBootstrapNodeStatus.RUNNING,
                    durationMs = null,
                    startedAtMs = nowMs,
                )
                node.status == DemoBootstrapNodeStatus.RUNNING ->
                    // 不允许同时有多个 RUNNING；若有则保持已有完成态逻辑由 complete 负责
                    node
                else -> node
            }
        }
        snapshot = snapshot.copy(nodes = nodes, failed = false, totalMs = null, completedAtMs = null)
        return snapshot
    }

    fun complete(stage: DemoBootstrapStage, nowMs: Long = System.currentTimeMillis()): DemoBootstrapSnapshot {
        val nodes = snapshot.nodes.map { node ->
            if (node.stage != stage) return@map node
            val start = node.startedAtMs ?: snapshot.startedAtMs ?: nowMs
            node.copy(
                status = DemoBootstrapNodeStatus.DONE,
                durationMs = (nowMs - start).coerceAtLeast(0L),
                startedAtMs = start,
            )
        }
        var next = snapshot.copy(nodes = nodes, failed = false)
        if (stage == DemoBootstrapStage.CHANNEL_READY) {
            val totalStart = next.startedAtMs ?: nowMs
            next = next.copy(
                totalMs = (nowMs - totalStart).coerceAtLeast(0L),
                completedAtMs = nowMs,
            )
        }
        snapshot = next
        return snapshot
    }

    fun fail(stage: DemoBootstrapStage, nowMs: Long = System.currentTimeMillis()): DemoBootstrapSnapshot {
        val nodes = snapshot.nodes.map { node ->
            if (node.stage != stage) return@map node
            val start = node.startedAtMs ?: snapshot.startedAtMs ?: nowMs
            node.copy(
                status = DemoBootstrapNodeStatus.FAILED,
                durationMs = (nowMs - start).coerceAtLeast(0L),
                startedAtMs = start,
            )
        }
        val totalStart = snapshot.startedAtMs
        snapshot = snapshot.copy(
            nodes = nodes,
            failed = true,
            totalMs = totalStart?.let { (nowMs - it).coerceAtLeast(0L) },
            completedAtMs = nowMs,
        )
        return snapshot
    }

    /** 通道对象已创建后，等待 RUNNING/DEGRADED。 */
    fun beginChannelReady(nowMs: Long = System.currentTimeMillis()): DemoBootstrapSnapshot {
        if (node(DemoBootstrapStage.CREATE_CHANNEL)?.status == DemoBootstrapNodeStatus.RUNNING) {
            complete(DemoBootstrapStage.CREATE_CHANNEL, nowMs)
        }
        return begin(DemoBootstrapStage.CHANNEL_READY, nowMs)
    }

    fun completeChannelReady(nowMs: Long = System.currentTimeMillis()): DemoBootstrapSnapshot {
        val ready = node(DemoBootstrapStage.CHANNEL_READY) ?: return snapshot
        if (ready.status == DemoBootstrapNodeStatus.DONE) return snapshot
        if (ready.status == DemoBootstrapNodeStatus.PENDING) {
            // 建通道回调时已是就绪：直接记 0ms 段耗时
            begin(DemoBootstrapStage.CHANNEL_READY, nowMs)
        }
        return complete(DemoBootstrapStage.CHANNEL_READY, nowMs)
    }

    private fun node(stage: DemoBootstrapStage): DemoBootstrapNodeSnapshot? =
        snapshot.nodes.firstOrNull { it.stage == stage }
}
