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
import co.timekettle.translation.enums.TmkRoomScenario

enum class OnlineRoomScenarioOption(
    val title: String,
    val roomScenario: TmkRoomScenario,
) {
    SPEECH_TO_SPEECH("语音到语音", TmkRoomScenario.TRANSLATE_SPEECH_TO_SPEECH),
    RECOGNIZE("单识别", TmkRoomScenario.RECOGNIZE),
    SPEECH_TO_TEXT("语音到文本", TmkRoomScenario.TRANSLATE_SPEECH_TO_TEXT);

    companion object {
        val defaultOption: OnlineRoomScenarioOption = SPEECH_TO_SPEECH
    }
}

@Composable
fun OnlineRoomScenarioDialog(
    title: String,
    initialOption: OnlineRoomScenarioOption,
    onDismiss: () -> Unit,
    onConfirm: (OnlineRoomScenarioOption) -> Unit,
) {
    var option by remember(initialOption) { mutableStateOf(initialOption) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(title) },
        text = {
            Column(Modifier.fillMaxWidth()) {
                OnlineRoomScenarioOption.entries.forEach { item ->
                    OnlineRoomScenarioRow(item, option) { option = it }
                }
            }
        },
        confirmButton = {
            Button(onClick = { onConfirm(option) }) {
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
private fun OnlineRoomScenarioRow(
    option: OnlineRoomScenarioOption,
    selected: OnlineRoomScenarioOption,
    onSelect: (OnlineRoomScenarioOption) -> Unit,
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
