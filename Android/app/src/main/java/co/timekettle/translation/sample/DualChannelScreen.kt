package co.timekettle.translation.sample

import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import androidx.activity.compose.BackHandler
import androidx.hilt.navigation.compose.hiltViewModel
import cafe.adriel.voyager.core.screen.Screen
import cafe.adriel.voyager.navigator.LocalNavigator
import cafe.adriel.voyager.navigator.currentOrThrow

data class DualChannelScreen(
    val sourceLang: String,
    val targetLang: String,
) : Screen {

    @Composable
    override fun Content() {
        val navigator = LocalNavigator.currentOrThrow
        val viewModel: Online1v1ViewModel = hiltViewModel()
        val isInitialized by viewModel.isInitialized.collectAsState()
        val isStarted by viewModel.isStarted.collectAsState()
        val isStarting by viewModel.isStarting.collectAsState()
        val useFixedAudio by viewModel.useFixedAudio.collectAsState()
        val bubbles by viewModel.bubbles.collectAsState()
        val lockedSourceLang by viewModel.sourceLang.collectAsState()
        val lockedTargetLang by viewModel.targetLang.collectAsState()

        LaunchedEffect(viewModel, sourceLang, targetLang) {
            viewModel.setLanguagesIfNeeded(sourceLang, targetLang)
        }
        BackHandler(enabled = true) { viewModel.stopTranslation(); navigator.pop() }
        DisposableEffect(Unit) { onDispose { viewModel.stopTranslation() } }

        Column(
            modifier = Modifier.fillMaxSize().padding(16.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Text("1v1 模式（双声道）", style = MaterialTheme.typography.headlineSmall, modifier = Modifier.padding(bottom = 16.dp))

            FixedLanguageSummary("左声道(源)", lockedSourceLang, "右声道(目标)", lockedTargetLang, Modifier.padding(bottom = 16.dp))

            Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Button(onClick = { viewModel.initSDK() }, enabled = !isInitialized, modifier = Modifier.fillMaxWidth()) {
                    Text(if (isInitialized) "已初始化 ✓" else "初始化 SDK")
                }
                Button(onClick = { viewModel.startTranslation() }, enabled = isInitialized && !isStarted && !isStarting, modifier = Modifier.fillMaxWidth(),
                    colors = ButtonDefaults.buttonColors(containerColor = Color(0xFF4CAF50))) { Text(if (isStarting) "正在启动..." else "开始翻译") }
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically) {
                    Text("右声道固定音频")
                    Switch(checked = useFixedAudio, onCheckedChange = { viewModel.toggleFixedAudio() }, enabled = !isStarted)
                }
                Button(onClick = { viewModel.stopTranslation() }, enabled = isStarted, modifier = Modifier.fillMaxWidth(),
                    colors = ButtonDefaults.buttonColors(containerColor = Color(0xFFF44336))) { Text("停止翻译") }
            }

            Spacer(Modifier.height(12.dp))

            BubbleList(rows = bubbles, modifier = Modifier.fillMaxWidth().weight(1f))
        }
    }
}
