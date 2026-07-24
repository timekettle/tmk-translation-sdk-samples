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

/**
 * 播放音源(左路/右路翻译)选择弹窗。在线与离线一对一 Demo 共用。
 *
 * 立体声 TTS 按此拆出对应一路播放;低延迟单路帧仅播选中音源那一路。切换为热生效,不重建通道。
 */
@Composable
fun OneToOnePlaybackModeDialog(
    initialMode: OneToOnePlaybackMode,
    onDismiss: () -> Unit,
    onConfirm: (OneToOnePlaybackMode) -> Unit,
) {
    var mode by remember(initialMode) { mutableStateOf(initialMode) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("设置播放音源") },
        text = {
            Column(Modifier.fillMaxWidth()) {
                OneToOnePlaybackMode.entries.forEach { item ->
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(vertical = 4.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        RadioButton(selected = mode == item, onClick = { mode = item })
                        Column {
                            Text(item.title)
                            Text(
                                if (item == OneToOnePlaybackMode.LEFT) "播放左路翻译音频" else "播放右路翻译音频",
                                style = MaterialTheme.typography.bodySmall,
                            )
                        }
                    }
                }
            }
        },
        confirmButton = {
            Button(onClick = { onConfirm(mode) }) { Text("确定") }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) { Text("取消") }
        },
    )
}
