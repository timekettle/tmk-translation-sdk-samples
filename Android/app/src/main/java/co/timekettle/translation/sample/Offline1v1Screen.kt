package co.timekettle.translation.sample

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import androidx.activity.compose.BackHandler
import androidx.hilt.navigation.compose.hiltViewModel
import cafe.adriel.voyager.core.screen.Screen
import cafe.adriel.voyager.navigator.LocalNavigator
import cafe.adriel.voyager.navigator.currentOrThrow
import co.timekettle.translation.enums.TmkOfflineAudioChannelMode

data class Offline1v1Screen(
    val sourceLang: String,
    val targetLang: String,
) : Screen {

    @Composable
    override fun Content() {
        val navigator = LocalNavigator.currentOrThrow
        val viewModel: Offline1v1ViewModel = hiltViewModel()
        val isModelReady by viewModel.isModelReady.collectAsState()
        val isDownloading by viewModel.isDownloading.collectAsState()
        val downloadProgress by viewModel.downloadProgress.collectAsState()
        val isInitialized by viewModel.isInitialized.collectAsState()
        val initErrorMessage by viewModel.initErrorMessage.collectAsState()
        val isStarted by viewModel.isStarted.collectAsState()
        val isChannelReady by viewModel.isChannelReady.collectAsState()
        val isStarting by viewModel.isStarting.collectAsState()
        val conversationErrorPrompt by viewModel.conversationErrorPrompt.collectAsState()
        val isCheckingOfflineSupport by viewModel.isCheckingOfflineSupport.collectAsState()
        val isOfflineSupported by viewModel.isOfflineSupported.collectAsState()
        val offlineSupportChecked by viewModel.offlineSupportChecked.collectAsState()
        val bubbles by viewModel.bubbles.collectAsState()
        val offlineModelPackages by viewModel.offlineModelPackages.collectAsState()
        val sourceLang by viewModel.sourceLang.collectAsState()
        val targetLang by viewModel.targetLang.collectAsState()
        val leftSpeakerGender by viewModel.leftSpeakerGender.collectAsState()
        val rightSpeakerGender by viewModel.rightSpeakerGender.collectAsState()
        val offlineAudioChannelMode by viewModel.offlineAudioChannelMode.collectAsState()
        var settingsExpanded by remember { mutableStateOf(false) }
        var showSpeakerDialog by remember { mutableStateOf(false) }
        var showTtsOutputDialog by remember { mutableStateOf(false) }
        var showDetailInfo by remember { mutableStateOf(false) }
        val offlineLanguageOptions = (rememberOfflineLanguageOptions().state
            as? LanguageOptionsState.Ready)?.options ?: emptyMap()

        LaunchedEffect(viewModel, this.sourceLang, this.targetLang) {
            viewModel.setLanguagesIfNeeded(this@Offline1v1Screen.sourceLang, this@Offline1v1Screen.targetLang)
            viewModel.initSDK()
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

        if (conversationErrorPrompt != null) {
            val prompt = conversationErrorPrompt!!
            AlertDialog(
                onDismissRequest = {},
                title = { Text(prompt.title) },
                text = { Text(prompt.message) },
                confirmButton = {
                    TextButton(onClick = { viewModel.recreateChannelAfterRuntimeFailure() }) {
                        Text(prompt.restartText)
                    }
                },
                dismissButton = {
                    TextButton(onClick = {
                        viewModel.dismissConversationErrorPrompt()
                        viewModel.stop()
                        navigator.pop()
                    }) {
                        Text(prompt.leaveText)
                    }
                },
            )
        }

        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(16.dp),
            horizontalAlignment = Alignment.CenterHorizontally
        ) {
            Row(
                modifier = Modifier.fillMaxWidth().padding(bottom = 16.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    text = "离线 1v1 模式",
                    style = MaterialTheme.typography.headlineSmall,
                    modifier = Modifier.weight(1f)
                )
                Box {
                    TextButton(onClick = { settingsExpanded = true }) {
                        Text("设置")
                    }
                    DropdownMenu(
                        expanded = settingsExpanded,
                        onDismissRequest = { settingsExpanded = false },
                    ) {
                        DropdownMenuItem(
                            text = { Text("音色设置") },
                            onClick = {
                                settingsExpanded = false
                                showSpeakerDialog = true
                            },
                        )
                        DropdownMenuItem(
                            text = { Text("TTS输出方式: ${offlineAudioChannelMode.displayName()}") },
                            onClick = {
                                settingsExpanded = false
                                showTtsOutputDialog = true
                            },
                        )
                    }
                }
            }

            val statusText = when {
                initErrorMessage != null -> "SDK 初始化失败"
                isCheckingOfflineSupport -> "正在鉴权并检查离线能力..."
                offlineSupportChecked && !isOfflineSupported -> "当前账号不支持离线翻译"
                isDownloading -> "模型下载中..."
                downloadProgress == "下载失败" -> "模型下载失败"
                downloadProgress == "下载已取消" -> "模型下载已取消"
                downloadProgress == "下载完成" && !isChannelReady && !isStarting && !isStarted -> "模型下载完成"
                !isModelReady -> "模型未下载"
                isStarted -> "正在收听中..."
                isChannelReady -> "离线一对一通道已就绪，可以开始收听"
                isStarting -> "正在创建离线一对一通道..."
                isInitialized -> "模型已就绪，正在创建离线通道..."
                else -> "模型已就绪，正在初始化..."
            }
            val connectionState = when {
                isStarted -> "收听中"
                isChannelReady -> "已连接"
                isStarting -> "连接中"
                isInitialized -> "初始化完成"
                else -> "未就绪"
            }
            TranslationStatusLine(statusText)
            TranslationLanguageLine(
                sourceLang = sourceLang,
                targetLang = targetLang,
                showDetailInfo = showDetailInfo,
                onToggleDetail = { showDetailInfo = !showDetailInfo },
                displayNames = offlineLanguageOptions,
            )

            if (showDetailInfo) {
                TranslationDetailPanel(
                    rows = listOf(
                        "连接：$connectionState",
                        "通道：one_to_one/offline",
                        "模型：${if (isModelReady) "已就绪" else "未下载"}",
                        "采样：配置16000Hz/2ch",
                        "输入：左声道固定PCM / 右声道麦克风",
                        "TTS输出：${offlineAudioChannelMode.displayName()}",
                    ),
                )
            }

            if (!isModelReady || isDownloading) {
                // 下载模型保持在主流程位置，避免隐藏关键前置操作。
                Row(modifier = Modifier.fillMaxWidth()) {
                    Button(
                        onClick = { viewModel.downloadModels() },
                        enabled = offlineSupportChecked && isOfflineSupported && !isModelReady && !isDownloading && !isCheckingOfflineSupport,
                        modifier = Modifier.weight(1f).height(40.dp),
                        colors = ButtonDefaults.buttonColors(containerColor = Color(0xFFFF9800))
                    ) {
                        Text(
                            when {
                                isModelReady -> "模型已就绪 ✓"
                                isDownloading -> "下载中..."
                                isCheckingOfflineSupport -> "鉴权检查中..."
                                offlineSupportChecked && !isOfflineSupported -> "不支持离线翻译"
                                else -> "下载当前双向模型"
                            }
                        )
                    }
                    Spacer(modifier = Modifier.width(8.dp))
                    OutlinedButton(
                        onClick = { viewModel.cancelDownloadModels() },
                        enabled = isDownloading,
                        modifier = Modifier.weight(1f).height(40.dp),
                    ) {
                        Text("取消")
                    }
                }

                if (isDownloading && downloadProgress.isNotEmpty()) {
                    Text(
                        text = downloadProgress,
                        style = MaterialTheme.typography.bodySmall,
                        color = Color(0xFF666666),
                        modifier = Modifier.fillMaxWidth().padding(horizontal = 4.dp)
                    )
                }
                Spacer(modifier = Modifier.height(6.dp))
            }

            OfflineModelPackageList(
                packages = offlineModelPackages,
                modifier = Modifier.padding(bottom = 6.dp),
            )

            TranslationStartStopButtons(
                startText = "开始收听",
                stopText = "停止收听",
                startEnabled = isModelReady && isChannelReady && !isStarted && !isStarting,
                stopEnabled = isStarted,
                onStart = { viewModel.start() },
                onStop = { viewModel.stopListening() },
            )

            Spacer(modifier = Modifier.height(6.dp))

            BubbleList(
                rows = bubbles,
                modifier = Modifier.fillMaxWidth().weight(1f),
                metaText = { row ->
                    "sessionId: ${row.sessionId}  bubbleId: ${row.bubbleId}\n" +
                        "通道: one_to_one/offline\n" +
                        "采样: 配置16000Hz/2ch  TTS输出:${offlineAudioChannelMode.displayName()}"
                },
                scrollOnLatestUpdate = true,
            )
        }

        if (showSpeakerDialog) {
            Offline1v1SpeakerDialog(
                initialLeftGender = leftSpeakerGender,
                initialRightGender = rightSpeakerGender,
                onDismiss = { showSpeakerDialog = false },
                onConfirm = { left, right ->
                    showSpeakerDialog = false
                    viewModel.updateSpeakers(left, right)
                },
            )
        }

        if (showTtsOutputDialog) {
            Offline1v1TtsOutputModeDialog(
                initialMode = offlineAudioChannelMode,
                onDismiss = { showTtsOutputDialog = false },
                onConfirm = { mode ->
                    showTtsOutputDialog = false
                    viewModel.setOfflineAudioChannelMode(mode)
                },
            )
        }
    }
}

private fun TmkOfflineAudioChannelMode.displayName(): String = when (this) {
    TmkOfflineAudioChannelMode.MONO -> "Mono"
    TmkOfflineAudioChannelMode.STEREO -> "Stereo"
}
