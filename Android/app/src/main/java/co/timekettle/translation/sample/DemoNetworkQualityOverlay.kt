package co.timekettle.translation.sample

import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.delay
import kotlin.math.roundToInt

private val OverlayBg = Color(0xB8141822) // 半透明深色底
private val OverlayText = Color(0xFFF2F4F8)
private val OverlayDim = Color(0xFFB8BECF)
private val OverlayOk = Color(0xFF2ECC71)
private val OverlayRun = Color(0xFFF1C40F)
private val OverlayFail = Color(0xFFE74C3C)

@Composable
fun DraggableDemoNetworkQualityOverlay(
    snapshot: DemoOnlineNetworkStatsSnapshot,
    bootstrap: DemoBootstrapSnapshot,
    wifiSpeed: DemoWifiSpeedSnapshot,
) {
    var offset by remember { mutableStateOf(Offset.Zero) }
    var overlaySize by remember { mutableStateOf(IntSize.Zero) }
    var containerSize by remember { mutableStateOf(IntSize.Zero) }
    val marginPx = with(androidx.compose.ui.platform.LocalDensity.current) { 16.dp.roundToPx() }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .onSizeChanged { containerSize = it },
    ) {
        DemoNetworkQualityOverlay(
            snapshot = snapshot,
            bootstrap = bootstrap,
            wifiSpeed = wifiSpeed,
            modifier = Modifier
                .align(Alignment.TopEnd)
                .padding(top = 16.dp, end = 16.dp)
                .offset { IntOffset(offset.x.roundToInt(), offset.y.roundToInt()) }
                .onSizeChanged { overlaySize = it }
                .pointerInput(containerSize, overlaySize) {
                    detectDragGestures { change, dragAmount ->
                        val minX = (overlaySize.width + 2 * marginPx - containerSize.width)
                            .coerceAtMost(0)
                            .toFloat()
                        val maxY = (containerSize.height - overlaySize.height - 2 * marginPx)
                            .coerceAtLeast(0)
                            .toFloat()
                        offset = Offset(
                            x = (offset.x + dragAmount.x).coerceIn(minX, 0f),
                            y = (offset.y + dragAmount.y).coerceIn(-marginPx.toFloat(), maxY),
                        )
                        change.consume()
                    }
                },
        )
    }
}

/**
 * Demo 调试浮窗：
 * - 上丢 / 下丢
 * - Wi-Fi 测速（10s 平均带宽 + 业务延迟；&lt;100kbps 标红）
 * - bootstrap 链路各段耗时 + 完成总耗时
 */
@Composable
fun DemoNetworkQualityOverlay(
    snapshot: DemoOnlineNetworkStatsSnapshot,
    bootstrap: DemoBootstrapSnapshot = DemoBootstrapSnapshot(),
    wifiSpeed: DemoWifiSpeedSnapshot = DemoWifiSpeedSnapshot(),
    modifier: Modifier = Modifier,
) {
    var nowMs by remember { mutableLongStateOf(System.currentTimeMillis()) }
    LaunchedEffect(bootstrap.isRunning) {
        while (bootstrap.isRunning) {
            nowMs = System.currentTimeMillis()
            delay(200)
        }
        nowMs = System.currentTimeMillis()
    }

    val totalColor = when {
        bootstrap.failed -> OverlayFail
        bootstrap.totalMs != null -> OverlayOk
        bootstrap.isRunning -> OverlayRun
        else -> OverlayDim
    }

    val wifiColor = when {
        wifiSpeed.status == DemoWifiSpeedStatus.FAILED -> OverlayFail
        wifiSpeed.status == DemoWifiSpeedStatus.RUNNING -> OverlayRun
        wifiSpeed.isBandwidthPoor -> OverlayFail
        wifiSpeed.status == DemoWifiSpeedStatus.DONE -> OverlayOk
        else -> OverlayDim
    }

    Surface(
        modifier = modifier,
        shape = RoundedCornerShape(10.dp),
        color = OverlayBg,
        tonalElevation = 2.dp,
    ) {
        Column(modifier = Modifier.padding(horizontal = 10.dp, vertical = 8.dp)) {
            Text(
                text = "上丢（${snapshot.formatLoss(snapshot.txLossRate)}）  下丢（${snapshot.formatLoss(snapshot.rxLossRate)}）",
                color = OverlayText,
                fontSize = 11.sp,
                fontWeight = FontWeight.Medium,
            )

            Spacer(modifier = Modifier.size(4.dp))

            Text(
                text = wifiSpeed.displayLine(),
                color = wifiColor,
                fontSize = 11.sp,
                fontWeight = FontWeight.Medium,
            )

            Spacer(modifier = Modifier.size(6.dp))

            Text(
                text = bootstrap.totalLine(nowMs),
                color = totalColor,
                fontSize = 11.sp,
                fontWeight = FontWeight.SemiBold,
            )

            Spacer(modifier = Modifier.size(2.dp))

            Text(
                text = bootstrap.summaryLine(nowMs),
                color = OverlayDim,
                fontSize = 10.sp,
                fontWeight = FontWeight.Normal,
            )
        }
    }
}
