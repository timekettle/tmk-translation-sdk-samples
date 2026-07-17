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
import co.timekettle.translation.enums.TmkDialogConversationAudioMode

/**
 * 通道模式(标准/低延迟)选项的展示信息。
 *
 * 标准模式使用混合双声道(单 UID / 单连接);低延迟模式使用左右独立单声道(双 UID / 双连接),
 * 降低双方长时间连续说话时的延迟累积。
 */
enum class OnlineChannelAudioModeOption(
    val title: String,
    val subtitle: String,
    val audioMode: TmkDialogConversationAudioMode,
) {
    STANDARD("标准模式", "混合双声道 · 单 UID", TmkDialogConversationAudioMode.STANDARD),
    LOW_LATENCY("低延迟模式", "左右独立单声道 · 双 UID", TmkDialogConversationAudioMode.LOW_LATENCY);

    companion object {
        fun from(mode: TmkDialogConversationAudioMode): OnlineChannelAudioModeOption =
            entries.first { it.audioMode == mode }
    }
}

@Composable
fun OnlineChannelAudioModeDialog(
    initialMode: TmkDialogConversationAudioMode,
    onDismiss: () -> Unit,
    onConfirm: (TmkDialogConversationAudioMode) -> Unit,
) {
    var option by remember(initialMode) {
        mutableStateOf(OnlineChannelAudioModeOption.from(initialMode))
    }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("设置通道模式") },
        text = {
            Column(Modifier.fillMaxWidth()) {
                OnlineChannelAudioModeOption.entries.forEach { item ->
                    OnlineChannelAudioModeRow(item, option) { option = it }
                }
            }
        },
        confirmButton = {
            Button(onClick = { onConfirm(option.audioMode) }) {
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
private fun OnlineChannelAudioModeRow(
    option: OnlineChannelAudioModeOption,
    selected: OnlineChannelAudioModeOption,
    onSelect: (OnlineChannelAudioModeOption) -> Unit,
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
