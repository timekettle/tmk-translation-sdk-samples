package co.timekettle.translation.sample

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import androidx.activity.compose.BackHandler
import androidx.hilt.navigation.compose.hiltViewModel
import cafe.adriel.voyager.core.screen.Screen
import cafe.adriel.voyager.navigator.LocalNavigator
import cafe.adriel.voyager.navigator.currentOrThrow

data class OfflineListenScreen(
    val sourceLang: String,
    val targetLang: String,
) : Screen {

    @Composable
    override fun Content() {
        val navigator = LocalNavigator.currentOrThrow
        val viewModel: OfflineListenViewModel = hiltViewModel()
        val isModelReady by viewModel.isModelReady.collectAsState()
        val isDownloading by viewModel.isDownloading.collectAsState()
        val downloadProgress by viewModel.downloadProgress.collectAsState()
        val isInitialized by viewModel.isInitialized.collectAsState()
        val initErrorMessage by viewModel.initErrorMessage.collectAsState()
        val isStarted by viewModel.isStarted.collectAsState()
        val isStarting by viewModel.isStarting.collectAsState()
        val logs by viewModel.logMessages.collectAsState()
        val bubbles by viewModel.bubbles.collectAsState()
        val sourceLang by viewModel.sourceLang.collectAsState()
        val targetLang by viewModel.targetLang.collectAsState()

        LaunchedEffect(viewModel, this.sourceLang, this.targetLang) {
            viewModel.setLanguagesIfNeeded(this@OfflineListenScreen.sourceLang, this@OfflineListenScreen.targetLang)
        }

        BackHandler(enabled = true) {
            viewModel.stop()
            navigator.pop()
        }

        DisposableEffect(Unit) {
            onDispose { viewModel.stop() }
        }

        if (initErrorMessage != null) {
            SampleInitErrorDialog(
                message = initErrorMessage!!,
                onDismiss = viewModel::dismissInitError,
            )
        }

        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(16.dp),
            horizontalAlignment = Alignment.CenterHorizontally
        ) {
            Text(
                text = "离线旁听模式",
                style = MaterialTheme.typography.headlineSmall,
                modifier = Modifier.padding(bottom = 16.dp)
            )

            FixedLanguageSummary(
                leftLabel = "源语言",
                leftLang = sourceLang,
                rightLabel = "目标语言",
                rightLang = targetLang,
                modifier = Modifier.padding(bottom = 8.dp)
            )

            Spacer(modifier = Modifier.height(8.dp))

            Column(
                modifier = Modifier.fillMaxWidth(),
                verticalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                // 下载模型
                Button(
                    onClick = { viewModel.downloadModels() },
                    enabled = !isModelReady && !isDownloading,
                    modifier = Modifier.fillMaxWidth(),
                    colors = ButtonDefaults.buttonColors(containerColor = Color(0xFFFF9800))
                ) {
                    Text(
                        when {
                            isModelReady -> "模型已就绪 ✓"
                            isDownloading -> "下载中..."
                            else -> "下载当前语言模型"
                        }
                    )
                }

                if (isDownloading && downloadProgress.isNotEmpty()) {
                    Text(
                        text = downloadProgress,
                        style = MaterialTheme.typography.bodySmall,
                        color = Color(0xFF666666),
                        modifier = Modifier.fillMaxWidth().padding(horizontal = 4.dp)
                    )
                }

                // 初始化
                Button(
                    onClick = { viewModel.initSDK() },
                    enabled = isModelReady && !isInitialized,
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Text(if (isInitialized) "已初始化 ✓" else "初始化 SDK")
                }

                // 开始
                Button(
                    onClick = { viewModel.start() },
                    enabled = isInitialized && !isStarted && !isStarting,
                    modifier = Modifier.fillMaxWidth(),
                    colors = ButtonDefaults.buttonColors(containerColor = Color(0xFF4CAF50))
                ) {
                    Text(if (isStarting) "正在启动..." else "开始翻译")
                }

                // 停止
                Button(
                    onClick = { viewModel.stop() },
                    enabled = isStarted,
                    modifier = Modifier.fillMaxWidth(),
                    colors = ButtonDefaults.buttonColors(containerColor = Color(0xFFF44336))
                ) {
                    Text("停止翻译")
                }
            }

            Spacer(modifier = Modifier.height(12.dp))

            BubbleList(rows = bubbles, modifier = Modifier.fillMaxWidth().weight(1f))
        }
    }
}
