package co.timekettle.translation.sample

// Created by XiongJinhui on 2026/8/31.

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Slider
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier

/** 对话页面的临时气泡保留数设置；仅确认后才把草稿值应用给 ViewModel。 */
@Composable
fun BubbleRetentionLimitDialog(
    initialLimit: Int,
    onDismiss: () -> Unit,
    onConfirm: (Int) -> Unit,
) {
    var draft by remember(initialLimit) { mutableFloatStateOf(initialLimit.toFloat()) }
    val limit = draft.toInt().coerceIn(
        DemoConversationBubbleAssembler.MIN_MAX_ROWS,
        DemoConversationBubbleAssembler.MAX_MAX_ROWS,
    )
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("保留气泡数量") },
        text = {
            Column {
                Text("当前保留最新 $limit 个气泡")
                Slider(
                    value = draft,
                    onValueChange = { draft = it },
                    valueRange = DemoConversationBubbleAssembler.MIN_MAX_ROWS.toFloat()..
                        DemoConversationBubbleAssembler.MAX_MAX_ROWS.toFloat(),
                    steps = DemoConversationBubbleAssembler.MAX_MAX_ROWS -
                        DemoConversationBubbleAssembler.MIN_MAX_ROWS - 1,
                )
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                    Text("${DemoConversationBubbleAssembler.MIN_MAX_ROWS}")
                    Text("${DemoConversationBubbleAssembler.MAX_MAX_ROWS}")
                }
            }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("取消") } },
        confirmButton = { TextButton(onClick = { onConfirm(limit) }) { Text("确定") } },
    )
}
