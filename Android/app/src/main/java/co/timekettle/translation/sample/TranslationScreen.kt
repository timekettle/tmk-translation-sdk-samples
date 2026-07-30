package co.timekettle.translation.sample

import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.activity.compose.BackHandler
import cafe.adriel.voyager.core.screen.Screen
import cafe.adriel.voyager.hilt.getViewModel
import cafe.adriel.voyager.navigator.LocalNavigator
import cafe.adriel.voyager.navigator.currentOrThrow

data class ListenModeScreen(
    val sourceLang: String,
    val targetLang: String,
) : Screen {

    @Composable
    override fun Content() {
        val navigator = LocalNavigator.currentOrThrow
        val viewModel: OnlineListenViewModel = getViewModel()
        val isInitialized by viewModel.isInitialized.collectAsState()
        val initErrorMessage by viewModel.initErrorMessage.collectAsState()
        val isStarted by viewModel.isStarted.collectAsState()
        val isChannelReady by viewModel.isChannelReady.collectAsState()
        val isLocaleUpdating by viewModel.isLocaleUpdating.collectAsState()
        val isTranslateEngineUpdating by viewModel.isTranslateEngineUpdating.collectAsState()
        val isScenarioUpdating by viewModel.isScenarioUpdating.collectAsState()
        val isStarting by viewModel.isStarting.collectAsState()
        val bubbles by viewModel.bubbles.collectAsState()
        val statusText by viewModel.statusText.collectAsState()
        val remoteCloseRoomPromptVisible by viewModel.remoteCloseRoomPromptVisible.collectAsState()
        val conversationErrorPrompt by viewModel.conversationErrorPrompt.collectAsState()
        val currentRoomNo by viewModel.currentRoomNo.collectAsState()
        val captureSampleRate by viewModel.captureSampleRate.collectAsState()
        val captureChannels by viewModel.captureChannels.collectAsState()
        val playbackChannels by viewModel.playbackChannels.collectAsState()
        val lockedSourceLang by viewModel.sourceLang.collectAsState()
        val lockedTargetLang by viewModel.targetLang.collectAsState()
        val speakerGender by viewModel.speakerGender.collectAsState()
        val onlineTranslateEngine by viewModel.onlineTranslateEngine.collectAsState()
        val roomScenarioOption by viewModel.roomScenarioOption.collectAsState()
        var settingsExpanded by remember { mutableStateOf(false) }
        var showLocaleDialog by remember { mutableStateOf(false) }
        var showSpeakerDialog by remember { mutableStateOf(false) }
        var showTranslateEngineDialog by remember { mutableStateOf(false) }
        var showRoomScenarioDialog by remember { mutableStateOf(false) }
        var showDetailInfo by remember { mutableStateOf(false) }
        val onlineLanguageOptions = (rememberOnlineLanguageOptions().state
            as? LanguageOptionsState.Ready)?.options ?: emptyMap()

        LaunchedEffect(viewModel, sourceLang, targetLang) {
            viewModel.setLanguagesIfNeeded(sourceLang, targetLang)
            viewModel.initSDK()
        }
        BackHandler(enabled = true) { navigator.pop() }
        DisposableEffect(Unit) { onDispose { viewModel.stopTranslation() } }

        if (initErrorMessage != null) {
            SampleInitErrorDialog(
                message = initErrorMessage!!,
                onDismiss = viewModel::dismissInitError,
            )
        }

        if (conversationErrorPrompt != null || remoteCloseRoomPromptVisible) {
            val prompt = conversationErrorPrompt ?: OnlineConversationErrorPrompts.fromCloseRoom()
            AlertDialog(
                onDismissRequest = {},
                title = { Text(prompt.title) },
                text = { Text(prompt.message) },
                confirmButton = {
                    TextButton(onClick = { viewModel.recreateChannelAfterRemoteClose() }) {
                        Text(prompt.restartText)
                    }
                },
                dismissButton = {
                    TextButton(onClick = {
                        viewModel.dismissRemoteCloseRoomPrompt()
                        viewModel.stopTranslation(prompt.title)
                        navigator.pop()
                    }) {
                        Text(prompt.leaveText)
                    }
                },
            )
        }

        Column(
            modifier = Modifier.fillMaxSize().padding(16.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Row(
                modifier = Modifier.fillMaxWidth().padding(bottom = 16.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    "旁听模式（单声道）",
                    style = MaterialTheme.typography.headlineSmall,
                    modifier = Modifier.weight(1f),
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
                            text = { Text(if (isLocaleUpdating) "切换中..." else "切换语言") },
                            enabled = !isLocaleUpdating,
                            onClick = {
                                settingsExpanded = false
                                showLocaleDialog = true
                            },
                        )
                        DropdownMenuItem(
                            text = { Text("音色设置") },
                            onClick = {
                                settingsExpanded = false
                                showSpeakerDialog = true
                            },
                        )
                        DropdownMenuItem(
                            text = { Text(if (isTranslateEngineUpdating) "翻译引擎切换中..." else "翻译引擎设置") },
                            enabled = !isTranslateEngineUpdating,
                            onClick = {
                                settingsExpanded = false
                                showTranslateEngineDialog = true
                            },
                        )
                        DropdownMenuItem(
                            text = { Text(if (isScenarioUpdating) "房间能力切换中..." else "房间能力设置") },
                            enabled = !isScenarioUpdating,
                            onClick = {
                                settingsExpanded = false
                                showRoomScenarioDialog = true
                            },
                        )
                    }
                }
            }

            val captureInfo = if (captureChannels > 0) "${captureSampleRate}Hz/${captureChannels}ch" else "-"
            val playbackInfo = if (playbackChannels > 0) "${playbackChannels}ch" else "-"
            val connectionState = when {
                isStarted -> "收听中"
                isChannelReady -> "已连接"
                isStarting -> "连接中"
                else -> "未连接"
            }
            TranslationStatusLine(statusText)
            TranslationLanguageLine(
                sourceLang = lockedSourceLang,
                targetLang = lockedTargetLang,
                showDetailInfo = showDetailInfo,
                onToggleDetail = { showDetailInfo = !showDetailInfo },
                bidirectional = false,
                displayNames = onlineLanguageOptions,
            )

            if (showDetailInfo) {
                TranslationDetailPanel(
                    rows = listOf(
                        "连接：$connectionState",
                        "房间：$currentRoomNo",
                        "能力：${roomScenarioOption.title}",
                        "通道：listen/online",
                        "采样：配置16000Hz/1ch  采集$captureInfo  回放$playbackInfo",
                    ),
                )
            }

            TranslationStartStopButtons(
                startText = "开始收听",
                stopText = "停止收听",
                startEnabled = isChannelReady && !isStarted && !isStarting,
                stopEnabled = isStarted,
                onStart = { viewModel.startTranslation() },
                onStop = { viewModel.stopListening() },
            )

            Spacer(Modifier.height(6.dp))

            BubbleList(
                rows = bubbles,
                modifier = Modifier.fillMaxWidth().weight(1f),
                metaText = { row ->
                    val capture = if (captureChannels > 0) "${captureSampleRate}Hz/${captureChannels}ch" else "-"
                    val playback = if (playbackChannels > 0) "${playbackChannels}ch" else "-"
                    "sessionId: ${row.sessionId}  bubbleId: ${row.bubbleId}\n" +
                        "房间: $currentRoomNo  通道: listen/online\n" +
                        "能力: ${roomScenarioOption.title}\n" +
                        "采样: 配置16000Hz/1ch  采集$capture  回放$playback"
                },
                scrollOnLatestUpdate = true,
            )
        }

        if (showLocaleDialog) {
            OnlineLocaleSwitchDialog(
                title = "切换旁听语言",
                sourceLabel = "源语言",
                targetLabel = "目标语言",
                initialSourceLang = lockedSourceLang,
                initialTargetLang = lockedTargetLang,
                languageOptions = onlineLanguageOptions,
                onDismiss = { showLocaleDialog = false },
                onConfirm = { source, target ->
                    showLocaleDialog = false
                    viewModel.updateRoomLocale(source, target)
                },
            )
        }

        if (showSpeakerDialog) {
            OfflineListenSpeakerDialog(
                initialGender = speakerGender,
                onDismiss = { showSpeakerDialog = false },
                onConfirm = {
                    showSpeakerDialog = false
                    viewModel.updateSpeaker(it)
                },
            )
        }

        if (showTranslateEngineDialog) {
            OnlineTranslateEngineDialog(
                initialEngine = onlineTranslateEngine,
                onDismiss = { showTranslateEngineDialog = false },
                onConfirm = {
                    showTranslateEngineDialog = false
                    viewModel.updateTranslateEngine(it)
                },
            )
        }

        if (showRoomScenarioDialog) {
            OnlineRoomScenarioDialog(
                title = "设置在线收听房间能力",
                initialOption = roomScenarioOption,
                onDismiss = { showRoomScenarioDialog = false },
                onConfirm = {
                    showRoomScenarioDialog = false
                    viewModel.updateRoomScenario(it)
                },
            )
        }
    }
}
