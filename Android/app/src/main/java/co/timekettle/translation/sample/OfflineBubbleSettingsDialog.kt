package co.timekettle.translation.sample

import co.timekettle.translation.*

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Switch
import androidx.compose.material3.Slider
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import kotlin.math.roundToInt

@Composable
fun OfflineBubbleSettingsDialog(
    lengthSplitEnabled: Boolean,
    onLengthSplitEnabledChange: (Boolean) -> Unit,
    thresholdUnits: Int,
    onThresholdUnitsChange: (Int) -> Unit,
    onDismiss: () -> Unit,
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("气泡设置") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
                var sliderValue by remember(thresholdUnits) { mutableFloatStateOf(thresholdUnits.toFloat()) }
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Column(modifier = Modifier.weight(1f)) {
                        Text(
                            text = "达到字符阈值分气泡",
                            style = MaterialTheme.typography.titleSmall,
                            fontWeight = FontWeight.Medium,
                        )
                        Text(
                            text = "修改后会重启离线翻译通道",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                    Switch(
                        checked = lengthSplitEnabled,
                        onCheckedChange = onLengthSplitEnabledChange,
                    )
                }
                Column {
                    Text("分泡单位：${sliderValue.roundToInt()}", style = MaterialTheme.typography.titleSmall)
                    Slider(
                        value = sliderValue,
                        onValueChange = { sliderValue = it },
                        valueRange = 10f..500f,
                        steps = 489,
                        onValueChangeFinished = { onThresholdUnitsChange(sliderValue.roundToInt()) },
                    )
                    Text("范围 10～500，按语种计量单位累计", style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                HorizontalDivider()
                Text(
                    text = "BubbleEnd 边框颜色",
                    style = MaterialTheme.typography.titleSmall,
                    fontWeight = FontWeight.Medium,
                )
                BubbleEndColorLegend(
                    colors = listOf(Color(0xFF34C759), Color(0xFF0A84FF)),
                    title = "正常 final",
                    detail = "保持当前气泡的默认边框色",
                )
                BubbleEndColorLegend(
                    colors = listOf(Color(0xFFFFCC00)),
                    title = "达到字符阈值",
                    detail = "黄色边框",
                )
                BubbleEndColorLegend(
                    colors = listOf(Color(0xFFFF3B30)),
                    title = "异常结束",
                    detail = "红色边框",
                )
                BubbleEndColorLegend(
                    colors = listOf(Color(0xFFAF52DE)),
                    title = "其他结束原因",
                    detail = "紫色边框",
                )
            }
        },
        confirmButton = {
            TextButton(onClick = onDismiss) { Text("完成") }
        },
    )
}

@Composable
private fun BubbleEndColorLegend(
    colors: List<Color>,
    title: String,
    detail: String,
) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Row(
            modifier = Modifier.width(42.dp),
            horizontalArrangement = Arrangement.spacedBy(5.dp),
        ) {
            colors.forEach { color ->
                Box(
                    modifier = Modifier
                        .size(14.dp)
                        .background(color, CircleShape),
                )
            }
        }
        Column(modifier = Modifier.padding(start = 2.dp)) {
            Text(
                text = title,
                style = MaterialTheme.typography.bodyMedium,
                fontWeight = FontWeight.Medium,
            )
            Text(
                text = detail,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}
