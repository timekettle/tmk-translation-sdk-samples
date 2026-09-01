package co.timekettle.translation.sample

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import cafe.adriel.voyager.core.screen.Screen
import cafe.adriel.voyager.hilt.getViewModel
import cafe.adriel.voyager.navigator.LocalNavigator
import cafe.adriel.voyager.navigator.currentOrThrow

data class ChannelRaceStressScreen(
    val sourceLang: String = "en-US",
    val targetLang: String = "zh-CN",
) : Screen {

    @Composable
    override fun Content() {
        val navigator = LocalNavigator.currentOrThrow
        val viewModel: ChannelRaceStressViewModel = getViewModel()
        val state by viewModel.uiState.collectAsState()
        var rounds by remember { mutableStateOf("3") }
        var overlapMs by remember { mutableStateOf("500") }
        var holdMs by remember { mutableStateOf("8000") }
        var timeoutSeconds by remember { mutableStateOf("60") }

        fun leave() {
            viewModel.stop()
            navigator.pop()
        }

        BackHandler(onBack = ::leave)
        DisposableEffect(Unit) { onDispose { viewModel.stop() } }

        Column(
            modifier = Modifier.fillMaxSize().padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Row(modifier = Modifier.fillMaxWidth()) {
                Text("建链竞态压测", style = MaterialTheme.typography.headlineSmall, modifier = Modifier.weight(1f))
                TextButton(onClick = ::leave) { Text("返回") }
            }
            Text(
                "复刻 A 启动中又创建 B 的场景。修复后预期：B 立即返回 INVALID_STATE，A 正常完成，" +
                    "不再等待 60s timeout。运行期间请保持 App 在前台。",
                style = MaterialTheme.typography.bodySmall,
            )

            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                NumberField("轮数", rounds, { rounds = it }, Modifier.weight(1f), state.running)
                NumberField("重叠间隔 ms", overlapMs, { overlapMs = it }, Modifier.weight(1f), state.running)
            }
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                NumberField("B 保持 ms", holdMs, { holdMs = it }, Modifier.weight(1f), state.running)
                NumberField("Channel 超时 s", timeoutSeconds, { timeoutSeconds = it }, Modifier.weight(1f), state.running)
            }

            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Button(
                    onClick = {
                        viewModel.start(
                            ChannelRaceStressConfig(
                                rounds = rounds.toIntOrNull() ?: 3,
                                overlapDelayMs = overlapMs.toLongOrNull() ?: 500,
                                successfulChannelHoldMs = holdMs.toLongOrNull() ?: 8_000,
                                channelTimeoutMs = (timeoutSeconds.toLongOrNull() ?: 60) * 1_000,
                                sourceLang = sourceLang,
                                targetLang = targetLang,
                            ),
                        )
                    },
                    enabled = !state.running,
                    modifier = Modifier.weight(1f),
                ) { Text("开始压测") }
                OutlinedButton(
                    onClick = viewModel::stop,
                    enabled = state.running,
                    modifier = Modifier.weight(1f),
                ) { Text("停止并清理") }
                OutlinedButton(onClick = viewModel::clearLogs, enabled = !state.running) { Text("清空") }
            }

            Card(modifier = Modifier.fillMaxWidth()) {
                Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                    Text("状态：${state.status}", style = MaterialTheme.typography.titleSmall)
                    Text("进度：${state.completedRounds}/${rounds.toIntOrNull() ?: 3}，当前第 ${state.currentRound} 轮")
                    Text(
                        "保护=${state.protectedRounds}  复现=${state.reproducedRounds}  success=${state.successes}  " +
                            "failure=${state.failures}  timeout=${state.timeouts}",
                    )
                }
            }

            Text("实时日志（Logcat tag: ChannelRaceStress）", style = MaterialTheme.typography.titleSmall)
            LazyColumn(modifier = Modifier.fillMaxWidth().weight(1f)) {
                items(state.logs.asReversed()) { line ->
                    Text(
                        line,
                        style = MaterialTheme.typography.bodySmall,
                        fontFamily = FontFamily.Monospace,
                        modifier = Modifier.fillMaxWidth().padding(vertical = 2.dp),
                    )
                }
            }
            Spacer(Modifier.height(2.dp))
        }
    }
}

@Composable
private fun NumberField(
    label: String,
    value: String,
    onValueChange: (String) -> Unit,
    modifier: Modifier,
    disabled: Boolean,
) {
    OutlinedTextField(
        value = value,
        onValueChange = { input -> onValueChange(input.filter(Char::isDigit).take(6)) },
        label = { Text(label) },
        singleLine = true,
        enabled = !disabled,
        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
        modifier = modifier,
    )
}
