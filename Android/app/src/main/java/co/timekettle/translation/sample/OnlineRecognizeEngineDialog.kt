package co.timekettle.translation.sample

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
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
import co.timekettle.translation.enums.TmkOnlineRecognizeEngine

enum class OnlineRecognizeEngineOption(
    val title: String,
    val recognizeEngine: TmkOnlineRecognizeEngine,
) {
    DEFAULT("默认", TmkOnlineRecognizeEngine.DEFAULT),
    END_TO_END("端到端", TmkOnlineRecognizeEngine.END_TO_END),
    THREE_STAGE("三段式", TmkOnlineRecognizeEngine.THREE_STAGE);

    companion object {
        fun from(engine: TmkOnlineRecognizeEngine): OnlineRecognizeEngineOption =
            entries.first { it.recognizeEngine == engine }
    }
}

@Composable
fun OnlineRecognizeEngineDialog(
    initialEngine: TmkOnlineRecognizeEngine,
    onDismiss: () -> Unit,
    onConfirm: (TmkOnlineRecognizeEngine) -> Unit,
) {
    var option by remember(initialEngine) {
        mutableStateOf(OnlineRecognizeEngineOption.from(initialEngine))
    }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("设置识别引擎") },
        text = {
            Column(Modifier.fillMaxWidth()) {
                OnlineRecognizeEngineOption.entries.forEach { item ->
                    OnlineRecognizeEngineRow(item, option) { option = it }
                }
            }
        },
        confirmButton = {
            Button(onClick = { onConfirm(option.recognizeEngine) }) {
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
private fun OnlineRecognizeEngineRow(
    option: OnlineRecognizeEngineOption,
    selected: OnlineRecognizeEngineOption,
    onSelect: (OnlineRecognizeEngineOption) -> Unit,
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
        Text(option.title)
    }
}
