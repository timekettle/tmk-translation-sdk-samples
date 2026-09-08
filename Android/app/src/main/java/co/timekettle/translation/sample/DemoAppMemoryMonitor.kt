package co.timekettle.translation.sample

import android.content.Context
import android.os.Debug
import android.os.SystemClock
import android.util.Log
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Popup
import androidx.compose.ui.window.PopupProperties
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.Locale
import java.util.UUID
import kotlin.math.abs
import kotlin.math.roundToInt

internal enum class DemoMemoryTrend(val label: String) {
    OBSERVING("观察中"), STABLE("稳定"), GROWING("持续上涨")
}

internal data class DemoAndroidMemoryBreakdown(
    val totalPssMb: Double,
    val javaHeapMb: Double?,
    val nativeHeapMb: Double?,
    val graphicsMb: Double?,
    val codeMb: Double?,
    val stackMb: Double?,
    val privateOtherMb: Double?,
    val systemMb: Double?,
    val swapPssMb: Double?,
)

internal data class DemoMemoryCheckpoint(
    val minute: Int,
    val memoryMb: Double,
    val growthMb: Double,
    val trend: DemoMemoryTrend,
)

internal data class DemoAppMemorySnapshot(
    val breakdown: DemoAndroidMemoryBreakdown? = null,
    val pageEnterMb: Double? = null,
    val runtimeReadyMb: Double? = null,
    val runStartMb: Double? = null,
    val checkpoints: List<DemoMemoryCheckpoint> = emptyList(),
    val trend: DemoMemoryTrend = DemoMemoryTrend.OBSERVING,
    val visible: Boolean = true,
    val detailExpanded: Boolean = false,
)

internal object DemoMemoryTrendEvaluator {
    fun evaluate(elapsedMs: Long, newest: Double?, middle: Double?, oldest: Double?): DemoMemoryTrend {
        if (elapsedMs < 15 * 60_000L) return DemoMemoryTrend.OBSERVING
        if (newest == null || middle == null || oldest == null) return DemoMemoryTrend.STABLE
        val growth = newest - oldest
        val slopeMbPerMinute = growth / 10.0
        return if (oldest < middle && middle < newest && growth >= 15.0 && slopeMbPerMinute >= 1.0) {
            DemoMemoryTrend.GROWING
        } else DemoMemoryTrend.STABLE
    }
}

internal class DemoAppMemoryMonitor(
    private val context: Context,
    private val mode: String,
    visibleByDefault: Boolean,
) {
    private data class Sample(val uptimeMs: Long, val memoryMb: Double)
    private val sessionId = UUID.randomUUID().toString()
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val samples = mutableListOf<Sample>()
    private val sampleMutex = Mutex()
    private val _snapshot = MutableStateFlow(DemoAppMemorySnapshot(visible = visibleByDefault))
    val snapshot: StateFlow<DemoAppMemorySnapshot> = _snapshot.asStateFlow()
    private var samplingJob: Job? = null
    private var runStartUptimeMs: Long? = null
    private var lastPersistedMinute = -1

    fun startPage() {
        if (samplingJob != null) return
        scope.launch { sample("PAGE_ENTER") }
        samplingJob = scope.launch {
            while (isActive) {
                delay(10_000)
                sample("SAMPLE")
            }
        }
    }

    fun markRuntimeReady() {
        if (_snapshot.value.runtimeReadyMb != null) return
        scope.launch { sample("RUNTIME_READY") { state, value -> state.copy(runtimeReadyMb = value) } }
    }

    fun markRunStarted() {
        if (runStartUptimeMs != null) return
        runStartUptimeMs = SystemClock.elapsedRealtime()
        scope.launch { sample("RUN_START") { state, value -> state.copy(runStartMb = value) } }
    }

    fun markRunStopped() { scope.launch { sample("RUN_STOP") } }
    fun show() { _snapshot.value = _snapshot.value.copy(visible = true) }
    fun hide() { _snapshot.value = _snapshot.value.copy(visible = false) }
    fun setVisible(visible: Boolean) { _snapshot.value = _snapshot.value.copy(visible = visible) }
    fun toggleDetail() { _snapshot.value = _snapshot.value.copy(detailExpanded = !_snapshot.value.detailExpanded) }

    fun stopPage() {
        samplingJob?.cancel()
        samplingJob = null
        scope.launch { sample("PAGE_EXIT", completed = true) }
    }

    private suspend fun sample(
        event: String,
        completed: Boolean = false,
        assignment: ((DemoAppMemorySnapshot, Double) -> DemoAppMemorySnapshot)? = null,
    ) = sampleMutex.withLock {
        val memory = readMemory()
        val now = SystemClock.elapsedRealtime()
        var state = _snapshot.value.copy(breakdown = memory)
        if (state.pageEnterMb == null) state = state.copy(pageEnterMb = memory.totalPssMb)
        if (assignment != null) state = assignment(state, memory.totalPssMb)
        samples += Sample(now, memory.totalPssMb)
        samples.removeAll { now - it.uptimeMs > 95 * 60_000L }
        state = updateTrendAndCheckpoints(state, now)
        _snapshot.value = state
        val elapsedMinute = runStartUptimeMs?.let { ((now - it) / 60_000L).toInt().coerceAtLeast(0) } ?: -1
        if (event != "SAMPLE" || elapsedMinute >= 0 && elapsedMinute != lastPersistedMinute) {
            lastPersistedMinute = elapsedMinute
            persist(event, completed, state)
        }
    }

    private fun updateTrendAndCheckpoints(state: DemoAppMemorySnapshot, now: Long): DemoAppMemorySnapshot {
        val started = runStartUptimeMs ?: return state
        val baseline = state.runStartMb ?: return state
        val elapsed = now - started
        fun window(offsetMinutes: Int): Double? = median(samples.filter {
            val age = now - it.uptimeMs
            age >= offsetMinutes * 60_000L && age < (offsetMinutes + 5) * 60_000L
        }.map { it.memoryMb })
        val trend = DemoMemoryTrendEvaluator.evaluate(elapsed, window(0), window(5), window(10))
        val points = state.checkpoints.toMutableList()
        for (minute in listOf(15, 30, 60, 90)) {
            if (elapsed < minute * 60_000L || points.any { it.minute == minute }) continue
            val target = started + minute * 60_000L
            val value = median(samples.filter { abs(it.uptimeMs - target) <= 60_000L }.map { it.memoryMb })
                ?: state.breakdown?.totalPssMb ?: baseline
            points += DemoMemoryCheckpoint(minute, value, value - baseline, trend)
        }
        return state.copy(trend = trend, checkpoints = points)
    }

    private fun readMemory(): DemoAndroidMemoryBreakdown {
        val info = Debug.MemoryInfo().also(Debug::getMemoryInfo)
        fun stat(key: String): Double? = info.getMemoryStat(key).toLongOrNull()?.let { it / 1024.0 }
        return DemoAndroidMemoryBreakdown(
            totalPssMb = stat("summary.total-pss") ?: info.totalPss / 1024.0,
            javaHeapMb = stat("summary.java-heap"), nativeHeapMb = stat("summary.native-heap"),
            graphicsMb = stat("summary.graphics"), codeMb = stat("summary.code"),
            stackMb = stat("summary.stack"), privateOtherMb = stat("summary.private-other"),
            systemMb = stat("summary.system"), swapPssMb = stat("summary.total-swap"),
        )
    }

    private fun median(values: List<Double>): Double? {
        if (values.isEmpty()) return null
        val sorted = values.sorted()
        val middle = sorted.size / 2
        return if (sorted.size % 2 == 0) (sorted[middle - 1] + sorted[middle]) / 2 else sorted[middle]
    }

    private fun persist(event: String, completed: Boolean, state: DemoAppMemorySnapshot) {
        val directory = File(context.cacheDir, "demo_memory_sessions").apply { mkdirs() }
        val file = File(directory, "android_${mode}_$sessionId.json")
        val checkpoints = JSONArray().apply {
            state.checkpoints.forEach { point ->
                put(JSONObject().put("minute", point.minute).put("memory_mb", point.memoryMb)
                    .put("growth_mb", point.growthMb).put("trend", point.trend.label))
            }
        }
        val payload = JSONObject()
            .put("platform", "Android").put("mode", mode).put("session_id", sessionId)
            .put("completed", completed).put("event", event).put("updated_at_ms", System.currentTimeMillis())
            .put("page_enter_mb", state.pageEnterMb).put("runtime_ready_mb", state.runtimeReadyMb)
            .put("run_start_mb", state.runStartMb).put("current_mb", state.breakdown?.totalPssMb)
            .put("trend", state.trend.label).put("checkpoints", checkpoints)
        val temporary = File(directory, "${file.name}.tmp")
        temporary.writeText(payload.toString(2))
        if (!temporary.renameTo(file)) { file.writeText(payload.toString(2)); temporary.delete() }
        directory.listFiles()?.sortedByDescending { it.lastModified() }?.drop(10)?.forEach { it.delete() }
        Log.i("DemoAppMemory", "mode=$mode event=$event memoryMb=${format(state.breakdown?.totalPssMb)} trend=${state.trend.label}")
    }

    private fun format(value: Double?): String = value?.let { String.format(Locale.US, "%.1f", it) } ?: "-"
}

@Composable
internal fun rememberDemoAppMemoryMonitor(mode: String, visibleByDefault: Boolean): DemoAppMemoryMonitor {
    val context = LocalContext.current.applicationContext
    val monitor = remember(mode, visibleByDefault) { DemoAppMemoryMonitor(context, mode, visibleByDefault) }
    DisposableEffect(monitor) {
        monitor.startPage()
        onDispose { monitor.stopPage() }
    }
    return monitor
}

@Composable
internal fun DemoMemoryMonitorSettingsItem(
    monitor: DemoAppMemoryMonitor,
    onDismiss: () -> Unit,
) {
    val snapshot by monitor.snapshot.collectAsState()
    DropdownMenuItem(
        text = { Text("内存监控") },
        trailingIcon = { Switch(checked = snapshot.visible, onCheckedChange = null) },
        onClick = {
            monitor.setVisible(!snapshot.visible)
            onDismiss()
        },
    )
}

@Composable
internal fun DemoAppMemoryOverlay(monitor: DemoAppMemoryMonitor) {
    val snapshot by monitor.snapshot.collectAsState()
    if (!snapshot.visible) return
    val density = LocalDensity.current
    val configuration = LocalConfiguration.current
    val maxX = with(density) { (configuration.screenWidthDp.dp - 220.dp).roundToPx().coerceAtLeast(0) }
    val maxY = with(density) { (configuration.screenHeightDp.dp - 280.dp).roundToPx().coerceAtLeast(0) }
    val offsetState = remember { androidx.compose.runtime.mutableStateOf(IntOffset(12, 18)) }
    Popup(
        alignment = androidx.compose.ui.Alignment.TopStart,
        offset = offsetState.value,
        properties = PopupProperties(focusable = false, dismissOnBackPress = false, dismissOnClickOutside = false),
    ) {
        Surface(
            modifier = Modifier.width(220.dp).pointerInput(Unit) {
                detectDragGestures { change, amount ->
                    change.consume()
                    offsetState.value = IntOffset(
                        (offsetState.value.x + amount.x.roundToInt()).coerceIn(0, maxX),
                        (offsetState.value.y + amount.y.roundToInt()).coerceIn(0, maxY),
                    )
                }
            },
            shape = RoundedCornerShape(10.dp), color = Color(0xDD141822), tonalElevation = 3.dp,
        ) {
            Column(Modifier.padding(horizontal = 10.dp, vertical = 7.dp)) {
                Row {
                    Text("APP 内存监控", color = Color.White, fontSize = 12.sp, fontWeight = FontWeight.SemiBold, modifier = Modifier.weight(1f))
                    TextButton(onClick = monitor::hide, modifier = Modifier.width(28.dp)) { Text("×", color = Color.White) }
                }
                val color = when (snapshot.trend) {
                    DemoMemoryTrend.GROWING -> Color(0xFFE74C3C)
                    DemoMemoryTrend.STABLE -> Color(0xFF2ECC71)
                    DemoMemoryTrend.OBSERVING -> Color(0xFFB8BECF)
                }
                Text(summaryText(snapshot), color = color, fontSize = 10.sp, fontFamily = FontFamily.Monospace, lineHeight = 14.sp)
                TextButton(onClick = monitor::toggleDetail) {
                    Text(if (snapshot.detailExpanded) "内存明细  ▼" else "内存明细  ▶", fontSize = 10.sp, color = Color(0xFFB8BECF))
                }
                if (snapshot.detailExpanded) {
                    Text(detailText(snapshot.breakdown), color = Color(0xFFB8BECF), fontSize = 9.sp, fontFamily = FontFamily.Monospace, lineHeight = 13.sp)
                }
            }
        }
    }
}

private fun summaryText(snapshot: DemoAppMemorySnapshot): String {
    fun value(v: Double?) = v?.let { String.format(Locale.US, "%.1f MB", it) } ?: "-"
    val points = listOf(15, 30, 60, 90).joinToString("\n") { minute ->
        val point = snapshot.checkpoints.firstOrNull { it.minute == minute }
        if (point == null) "${minute}分钟  等待中" else String.format(Locale.US, "%d分钟  %.1f MB  %+.1f MB", minute, point.memoryMb, point.growthMb)
    }
    return "当前  ${value(snapshot.breakdown?.totalPssMb)}  ${snapshot.trend.label}\n进入  ${value(snapshot.pageEnterMb)}\n就绪  ${value(snapshot.runtimeReadyMb)}\n启动  ${value(snapshot.runStartMb)}\n$points"
}

private fun detailText(value: DemoAndroidMemoryBreakdown?): String {
    if (value == null) return "等待采样"
    fun mb(v: Double?) = v?.let { String.format(Locale.US, "%.1f MB", it) } ?: "-"
    return "Total PSS      ${mb(value.totalPssMb)}\nJava Heap      ${mb(value.javaHeapMb)}\nNative Heap    ${mb(value.nativeHeapMb)}\nGraphics       ${mb(value.graphicsMb)}\nCode           ${mb(value.codeMb)}\nStack          ${mb(value.stackMb)}\nPrivate Other  ${mb(value.privateOtherMb)}\nSystem         ${mb(value.systemMb)}\nSwap PSS       ${mb(value.swapPssMb)}"
}
