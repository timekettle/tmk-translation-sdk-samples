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
import co.timekettle.translation.enums.TmkOnlineTranslateEngine

@Composable
fun OnlineTranslateEngineDialog(
    initialEngine: TmkOnlineTranslateEngine,
    onDismiss: () -> Unit,
    onConfirm: (TmkOnlineTranslateEngine) -> Unit,
) {
    var engine by remember(initialEngine) { mutableStateOf(initialEngine) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("设置翻译引擎") },
        text = {
            Column(Modifier.fillMaxWidth()) {
                OnlineTranslateEngineRow("自动", TmkOnlineTranslateEngine.AUTOMATIC, engine) { engine = it }
                OnlineTranslateEngineRow("快速", TmkOnlineTranslateEngine.FAST, engine) { engine = it }
                OnlineTranslateEngineRow("精准", TmkOnlineTranslateEngine.ACCURATE, engine) { engine = it }
            }
        },
        confirmButton = {
            Button(onClick = { onConfirm(engine) }) {
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
private fun OnlineTranslateEngineRow(
    label: String,
    engine: TmkOnlineTranslateEngine,
    selected: TmkOnlineTranslateEngine,
    onSelect: (TmkOnlineTranslateEngine) -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        RadioButton(
            selected = selected == engine,
            onClick = { onSelect(engine) },
        )
        Text(label)
    }
}
