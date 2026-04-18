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

data class ListenModeScreen(
    val sourceLang: String,
    val targetLang: String,
) : Screen {

    @Composable
    override fun Content() {
        val navigator = LocalNavigator.currentOrThrow
        val viewModel: OnlineListenViewModel = hiltViewModel()
        val isInitialized by viewModel.isInitialized.collectAsState()
        val initErrorMessage by viewModel.initErrorMessage.collectAsState()
        val isStarted by viewModel.isStarted.collectAsState()
        val isStarting by viewModel.isStarting.collectAsState()
        val bubbles by viewModel.bubbles.collectAsState()
        val lockedSourceLang by viewModel.sourceLang.collectAsState()
        val lockedTargetLang by viewModel.targetLang.collectAsState()

        LaunchedEffect(viewModel, sourceLang, targetLang) {
            viewModel.setLanguagesIfNeeded(sourceLang, targetLang)
        }
        BackHandler(enabled = true) { viewModel.stopTranslation(); navigator.pop() }
        DisposableEffect(Unit) { onDispose { viewModel.stopTranslation() } }

        if (initErrorMessage != null) {
            SampleInitErrorDialog(
                message = initErrorMessage!!,
                onDismiss = viewModel::dismissInitError,
            )
        }

        Column(
            modifier = Modifier.fillMaxSize().padding(16.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Text("旁听模式（单声道）", style = MaterialTheme.typography.headlineSmall, modifier = Modifier.padding(bottom = 16.dp))

            FixedLanguageSummary("源语言", lockedSourceLang, "目标语言", lockedTargetLang, Modifier.padding(bottom = 16.dp))

            Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Button(onClick = { viewModel.initSDK() }, enabled = !isInitialized, modifier = Modifier.fillMaxWidth()) {
                    Text(if (isInitialized) "已初始化 ✓" else "初始化 SDK")
                }
                Button(onClick = { viewModel.startTranslation() }, enabled = isInitialized && !isStarted && !isStarting, modifier = Modifier.fillMaxWidth(),
                    colors = ButtonDefaults.buttonColors(containerColor = Color(0xFF4CAF50))) { Text(if (isStarting) "正在启动..." else "开始翻译") }
                Button(onClick = { viewModel.stopTranslation() }, enabled = isStarted, modifier = Modifier.fillMaxWidth(),
                    colors = ButtonDefaults.buttonColors(containerColor = Color(0xFFF44336))) { Text("停止翻译") }
            }

            Spacer(Modifier.height(12.dp))

            BubbleList(rows = bubbles, modifier = Modifier.fillMaxWidth().weight(1f))
        }
    }
}
