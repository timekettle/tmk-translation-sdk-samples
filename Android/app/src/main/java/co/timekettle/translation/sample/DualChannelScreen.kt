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

data class DualChannelScreen(
    val leftLang: String,
    val rightLang: String,
) : Screen {

    @Composable
    override fun Content() {
        val navigator = LocalNavigator.currentOrThrow
        val viewModel: Online1v1ViewModel = getViewModel()
        val memoryMonitor = rememberDemoAppMemoryMonitor("online_one_to_one", visibleByDefault = false)
        val initErrorMessage by viewModel.initErrorMessage.collectAsState()
        val isStarted by viewModel.isStarted.collectAsState()
        val isChannelReady by viewModel.isChannelReady.collectAsState()
        val isLocaleUpdating by viewModel.isLocaleUpdating.collectAsState()
        val isTranslateEngineUpdating by viewModel.isTranslateEngineUpdating.collectAsState()
        val isScenarioUpdating by viewModel.isScenarioUpdating.collectAsState()
        val isStarting by viewModel.isStarting.collectAsState()
        val bubbles by viewModel.bubbles.collectAsState()
        val statusText by viewModel.statusText.collectAsState()
        val networkStats by viewModel.networkStats.collectAsState()
        val bootstrapStats by viewModel.bootstrapStats.collectAsState()
        val wifiSpeed by viewModel.wifiSpeed.collectAsState()
        val remoteCloseRoomPromptVisible by viewModel.remoteCloseRoomPromptVisible.collectAsState()
        val conversationErrorPrompt by viewModel.conversationErrorPrompt.collectAsState()
        val currentRoomNo by viewModel.currentRoomNo.collectAsState()
        val captureSampleRate by viewModel.captureSampleRate.collectAsState()
        val captureChannels by viewModel.captureChannels.collectAsState()
        val playbackChannels by viewModel.playbackChannels.collectAsState()
        val lockedLeftLang by viewModel.leftLang.collectAsState()
        val lockedRightLang by viewModel.rightLang.collectAsState()
        val leftSpeakerGender by viewModel.leftSpeakerGender.collectAsState()
        val rightSpeakerGender by viewModel.rightSpeakerGender.collectAsState()
        val onlineTranslateEngine by viewModel.onlineTranslateEngine.collectAsState()
        val onlineRecognizeEngine by viewModel.onlineRecognizeEngine.collectAsState()
        val translateMode by viewModel.translateMode.collectAsState()
        val roomScenarioOption by viewModel.roomScenarioOption.collectAsState()
        val audioMode by viewModel.audioMode.collectAsState()
        val playbackMode by viewModel.playbackMode.collectAsState()
        val bubbleRetentionLimit by viewModel.bubbleRetentionLimit.collectAsState()
        var settingsExpanded by remember { mutableStateOf(false) }
        var showLocaleDialog by remember { mutableStateOf(false) }
        var showSpeakerDialog by remember { mutableStateOf(false) }
        var showTranslateEngineDialog by remember { mutableStateOf(false) }
        var showRecognizeEngineDialog by remember { mutableStateOf(false) }
        var showTranslateModeDialog by remember { mutableStateOf(false) }
        var showRoomScenarioDialog by remember { mutableStateOf(false) }
        var showChannelAudioModeDialog by remember { mutableStateOf(false) }
        var showPlaybackModeDialog by remember { mutableStateOf(false) }
        var showBubbleRetentionLimitDialog by remember { mutableStateOf(false) }
        var showDetailInfo by remember { mutableStateOf(false) }
        val onlineLanguageOptions = (rememberOnlineLanguageOptions().state
            as? LanguageOptionsState.Ready)?.options ?: emptyMap()

        LaunchedEffect(viewModel, leftLang, rightLang) {
            viewModel.setLanguagesIfNeeded(leftLang, rightLang)
            viewModel.initSDK()
        }
        LaunchedEffect(isChannelReady) { if (isChannelReady) memoryMonitor.markRuntimeReady() }
        BackHandler(enabled = true) { navigator.pop() }
        DisposableEffect(Unit) { onDispose { viewModel.stopTranslation() } }
        DemoAppMemoryOverlay(memoryMonitor)

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
                    TextButton(onClick = {
                        if (prompt.id == "reconnect_timeout") {
                            viewModel.recreateChannelAfterReconnectTimeout()
                        } else {
                            viewModel.recreateChannelAfterRemoteClose()
                        }
                    }) {
                        Text(prompt.restartText)
                    }
                },
                dismissButton = {
                    TextButton(onClick = {
                        if (prompt.id == "reconnect_timeout") {
                            viewModel.continueWaitingAfterReconnectTimeout()
                        } else {
                            viewModel.dismissRemoteCloseRoomPrompt()
                            viewModel.stopTranslation(prompt.title)
                            navigator.pop()
                        }
                    }) {
                        Text(prompt.leaveText)
                    }
                },
            )
        }

        Box(modifier = Modifier.fillMaxSize()) {
            Column(
                modifier = Modifier.fillMaxSize().padding(16.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
            Row(
                modifier = Modifier.fillMaxWidth().padding(bottom = 16.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    "一对一",
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
                            text = { Text("保留气泡数量：$bubbleRetentionLimit") },
                            onClick = {
                                settingsExpanded = false
                                showBubbleRetentionLimitDialog = true
                            },
                        )
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
                            text = { Text("识别引擎设置") },
                            onClick = {
                                settingsExpanded = false
                                showRecognizeEngineDialog = true
                            },
                        )
                        DropdownMenuItem(
                            text = { Text("翻译下发模式") },
                            onClick = {
                                settingsExpanded = false
                                showTranslateModeDialog = true
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
                        DropdownMenuItem(
                            text = { Text("通道模式") },
                            onClick = {
                                settingsExpanded = false
                                showChannelAudioModeDialog = true
                            },
                        )
                        DropdownMenuItem(
                            text = { Text("播放音源") },
                            onClick = {
                                settingsExpanded = false
                                showPlaybackModeDialog = true
                            },
                        )
                        DemoMemoryMonitorSettingsItem(memoryMonitor) { settingsExpanded = false }
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
                // 通用语言行仍按 source→target 展示；一对一内部字段明确为右路→左路。
                sourceLang = lockedRightLang,
                targetLang = lockedLeftLang,
                showDetailInfo = showDetailInfo,
                onToggleDetail = { showDetailInfo = !showDetailInfo },
                displayNames = onlineLanguageOptions,
            )

            if (showDetailInfo) {
                TranslationDetailPanel(
                    rows = listOf(
                        "连接：$connectionState",
                        "房间：$currentRoomNo",
                        "能力：${roomScenarioOption.title}",
                        "下发：${OnlineTranslateModeOption.from(translateMode).title}",
                        "通道：one_to_one/online",
                        "模式：${OnlineChannelAudioModeOption.from(audioMode).title}",
                        "播放：${playbackMode.title}",
                        "采样：配置16000Hz/2ch  采集$captureInfo  回放$playbackInfo",
                        "输入：左声道固定PCM / 右声道麦克风",
                    ),
                )
            }

            TranslationStartStopButtons(
                startText = "开始收听",
                stopText = "停止收听",
                startEnabled = isChannelReady && !isStarted && !isStarting,
                stopEnabled = isStarted,
                onStart = { memoryMonitor.markRunStarted(); viewModel.startTranslation() },
                onStop = { memoryMonitor.markRunStopped(); viewModel.stopListening() },
            )

            Spacer(Modifier.height(6.dp))

            BubbleList(
                rows = bubbles,
                modifier = Modifier.fillMaxWidth().weight(1f),
                metaText = { row ->
                    val capture = if (captureChannels > 0) "${captureSampleRate}Hz/${captureChannels}ch" else "-"
                    val playback = if (playbackChannels > 0) "${playbackChannels}ch" else "-"
                    "sessionId: ${row.sessionId}  bubbleId: ${row.bubbleId}\n" +
                        "房间: $currentRoomNo  通道: one_to_one/online\n" +
                        "能力: ${roomScenarioOption.title}\n" +
                        "采样: 配置16000Hz/2ch  采集$capture  回放$playback"
                },
                scrollOnLatestUpdate = true,
            )
            }

            DraggableDemoNetworkQualityOverlay(
                snapshot = networkStats,
                bootstrap = bootstrapStats,
                wifiSpeed = wifiSpeed,
            )
        }

        if (showBubbleRetentionLimitDialog) {
            BubbleRetentionLimitDialog(
                initialLimit = bubbleRetentionLimit,
                onDismiss = { showBubbleRetentionLimitDialog = false },
                onConfirm = {
                    showBubbleRetentionLimitDialog = false
                    viewModel.setBubbleRetentionLimit(it)
                },
            )
        }
        if (showLocaleDialog) {
            OnlineLocaleSwitchDialog(
                title = "切换 1v1 语言",
                sourceLabel = "源语言（右声道）",
                targetLabel = "目标语言（左声道）",
                initialSourceLang = lockedRightLang,
                initialTargetLang = lockedLeftLang,
                languageOptions = onlineLanguageOptions,
                onDismiss = { showLocaleDialog = false },
                onConfirm = { source, target ->
                    showLocaleDialog = false
                    viewModel.updateRoomLocale(leftLang = target, rightLang = source)
                },
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

        if (showRecognizeEngineDialog) {
            OnlineRecognizeEngineDialog(
                initialEngine = onlineRecognizeEngine,
                onDismiss = { showRecognizeEngineDialog = false },
                onConfirm = {
                    showRecognizeEngineDialog = false
                    viewModel.setOnlineRecognizeEngine(it)
                },
            )
        }

        if (showTranslateModeDialog) {
            OnlineTranslateModeDialog(
                initialMode = translateMode,
                onDismiss = { showTranslateModeDialog = false },
                onConfirm = {
                    showTranslateModeDialog = false
                    viewModel.setTranslateMode(it)
                },
            )
        }

        if (showRoomScenarioDialog) {
            OnlineRoomScenarioDialog(
                title = "设置在线一对一房间能力",
                initialOption = roomScenarioOption,
                onDismiss = { showRoomScenarioDialog = false },
                onConfirm = {
                    showRoomScenarioDialog = false
                    viewModel.updateRoomScenario(it)
                },
            )
        }

        if (showChannelAudioModeDialog) {
            OnlineChannelAudioModeDialog(
                initialMode = audioMode,
                onDismiss = { showChannelAudioModeDialog = false },
                onConfirm = {
                    showChannelAudioModeDialog = false
                    // 切换通道模式:收听中也可切,切换后自动重建翻译引擎(房间+通道)使新模式生效。
                    viewModel.setAudioMode(it)
                },
            )
        }

        if (showPlaybackModeDialog) {
            OneToOnePlaybackModeDialog(
                initialMode = playbackMode,
                onDismiss = { showPlaybackModeDialog = false },
                onConfirm = {
                    showPlaybackModeDialog = false
                    // 切换本机播放身份:只播本机那一路 TTS,丢弃对侧(对齐 iOS)。热切换,清空播放缓冲。
                    viewModel.setPlaybackMode(it)
                },
            )
        }
    }
}
