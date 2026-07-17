package co.timekettle.translation.sample

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import co.timekettle.translation.enums.TmkTranslateDeliveryMode

/**
 * 离线翻译下发模式(partial/stable)选择弹窗——放入设置菜单,单选并高亮当前已选中项。
 *
 * 复用在线枚举 [TmkTranslateDeliveryMode];DEFAULT 语义等同 STABLE(离线 D1),故 UI 只暴露 PARTIAL/STABLE 两档。
 * 确定即调 onConfirm(通道就绪时立即下发,否则下次建通道生效)。中间态气泡渲染由现有 assembler 自动处理。
 */
enum class TranslateModeOption(
    val title: String,
    val subtitle: String,
    val mode: TmkTranslateDeliveryMode,
) {
    PARTIAL("中间态 partial", "识别中即送翻译 · 低时延", TmkTranslateDeliveryMode.PARTIAL),
    STABLE("稳定 stable", "断句成句后才翻译 · 更完整", TmkTranslateDeliveryMode.STABLE);

    companion object {
        /** DEFAULT 归一到 STABLE 展示(离线 D1)。 */
        fun from(mode: TmkTranslateDeliveryMode): TranslateModeOption =
            if (mode == TmkTranslateDeliveryMode.PARTIAL) PARTIAL else STABLE
    }
}

@Composable
fun TranslateModeDialog(
    initialMode: TmkTranslateDeliveryMode,
    onDismiss: () -> Unit,
    onConfirm: (TmkTranslateDeliveryMode) -> Unit,
) {
    var option by remember(initialMode) {
        mutableStateOf(TranslateModeOption.from(initialMode))
    }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("翻译下发模式") },
        text = {
            Column(Modifier.fillMaxWidth()) {
                TranslateModeOption.entries.forEach { item ->
                    TranslateModeRow(item, option) { option = it }
                }
            }
        },
        confirmButton = {
            Button(onClick = { onConfirm(option.mode) }) {
                Text("确定")
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) {
                Text("取消")
            }
        },
    )
}

@Composable
private fun TranslateModeRow(
    option: TranslateModeOption,
    selected: TranslateModeOption,
    onSelect: (TranslateModeOption) -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        RadioButton(
            selected = selected == option,
            onClick = { onSelect(option) },
        )
        Column {
            Text(option.title)
            Text(option.subtitle, style = MaterialTheme.typography.bodySmall)
        }
    }
}
