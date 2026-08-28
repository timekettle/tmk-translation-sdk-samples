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

/** 在线 Demo 使用的三档翻译下发模式；DEFAULT 保留服务端默认语义。 */
enum class OnlineTranslateModeOption(
    val title: String,
    val subtitle: String,
    val mode: TmkTranslateDeliveryMode,
) {
    DEFAULT("默认 default", "由服务端按默认策略处理", TmkTranslateDeliveryMode.DEFAULT),
    PARTIAL("中间态 partial", "识别中即送翻译 · 低时延", TmkTranslateDeliveryMode.PARTIAL),
    STABLE("稳定 stable", "断句成句后才翻译 · 更完整", TmkTranslateDeliveryMode.STABLE);

    companion object {
        fun from(mode: TmkTranslateDeliveryMode): OnlineTranslateModeOption =
            entries.first { it.mode == mode }
    }
}

@Composable
fun OnlineTranslateModeDialog(
    initialMode: TmkTranslateDeliveryMode,
    onDismiss: () -> Unit,
    onConfirm: (TmkTranslateDeliveryMode) -> Unit,
) {
    var option by remember(initialMode) {
        mutableStateOf(OnlineTranslateModeOption.from(initialMode))
    }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("翻译下发模式") },
        text = {
            Column(Modifier.fillMaxWidth()) {
                OnlineTranslateModeOption.entries.forEach { item ->
                    OnlineTranslateModeRow(item, option) { option = it }
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
private fun OnlineTranslateModeRow(
    option: OnlineTranslateModeOption,
    selected: OnlineTranslateModeOption,
    onSelect: (OnlineTranslateModeOption) -> Unit,
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
