package co.timekettle.translation.sample

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.sp
import androidx.compose.ui.unit.dp
import cafe.adriel.voyager.core.screen.Screen
import cafe.adriel.voyager.hilt.getViewModel
import cafe.adriel.voyager.navigator.LocalNavigator
import cafe.adriel.voyager.navigator.currentOrThrow

private val RuntimeStatusCardHeight = 96.dp

/** 在线和离线 Channel 并发的一对一演示页；TTS 来源和播放音源在独立设置窗口中调整。 */
data class ConcurrentOneToOneScreen(
    val leftLang: String,
    val rightLang: String,
) : Screen {
    @Composable
    override fun Content() {
        val navigator = LocalNavigator.currentOrThrow
        val viewModel: ConcurrentOneToOneViewModel = getViewModel()
        val state by viewModel.state.collectAsState()
        val memoryMonitor = rememberDemoAppMemoryMonitor("concurrent_one_to_one", visibleByDefault = true)

        LaunchedEffect(viewModel, leftLang, rightLang) { viewModel.prepare(leftLang, rightLang) }
        LaunchedEffect(state.canStart) { if (state.canStart) memoryMonitor.markRuntimeReady() }
        BackHandler { viewModel.release(); navigator.pop() }
        DisposableEffect(viewModel) { onDispose { viewModel.release() } }
        DemoAppMemoryOverlay(memoryMonitor)

        var controlsExpanded by rememberSaveable { mutableStateOf(true) }
        var settingsExpanded by rememberSaveable { mutableStateOf(false) }
        var showTtsSourceDialog by rememberSaveable { mutableStateOf(false) }
        var showPlaybackModeDialog by rememberSaveable { mutableStateOf(false) }
        var showBubbleRetentionLimitDialog by rememberSaveable { mutableStateOf(false) }
        Column(Modifier.fillMaxSize().padding(16.dp)) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Column(Modifier.weight(1f)) {
                    Text("一对一对话", style = MaterialTheme.typography.headlineSmall)
                    Text(
                        "在线和离线独立运行，各自按服务端气泡结果展示",
                        style = MaterialTheme.typography.bodySmall,
                        color = Color.Gray,
                    )
                }
                Spacer(Modifier.width(8.dp))
                Box {
                    TextButton(onClick = { settingsExpanded = true }) {
                        Text("设置")
                    }
                    DropdownMenu(
                        expanded = settingsExpanded,
                        onDismissRequest = { settingsExpanded = false },
                    ) {
                        DropdownMenuItem(
                            text = { Text("保留气泡数量：${state.bubbleRetentionLimit}") },
                            onClick = {
                                settingsExpanded = false
                                showBubbleRetentionLimitDialog = true
                            },
                        )
                        DropdownMenuItem(
                            text = { Text("TTS 来源") },
                            onClick = {
                                settingsExpanded = false
                                showTtsSourceDialog = true
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
            Row(
                modifier = Modifier.fillMaxWidth().padding(top = 8.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(if (controlsExpanded) "控制与状态" else "控制与状态（已收起）", style = MaterialTheme.typography.labelLarge)
                Spacer(Modifier.weight(1f))
                OutlinedButton(onClick = { controlsExpanded = !controlsExpanded }) {
                    Text(if (controlsExpanded) "收起" else "展开")
                }
            }
            if (controlsExpanded) {
                Spacer(Modifier.height(2.dp))
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    RuntimeCard(
                        title = "在线",
                        // 一对一语言可双向互译，代码字段仍按左右路保存。
                        language = "$rightLang ↔ $leftLang",
                        status = state.onlineStatus,
                        color = Color(0xFF00B894),
                        retryEnabled = state.onlineCanRetry,
                        retry = viewModel::retryOnline,
                        modifier = Modifier.weight(1f),
                    )
                    RuntimeCard(
                        title = "离线",
                        language = "${rightLang.baseLanguageCode()} ↔ ${leftLang.baseLanguageCode()}",
                        status = "${state.offlineStatus} · ${state.modelStatus}",
                        color = Color(0xFFE17055),
                        retryEnabled = state.offlineCanRetry,
                        retry = viewModel::retryOffline,
                        modifier = Modifier.weight(1f),
                    )
                }
                if (state.modelTotalProgressText.isNotEmpty()) {
                    Text(
                        state.modelTotalProgressText,
                        style = MaterialTheme.typography.bodySmall,
                        color = Color(0xFF8A4B08),
                        modifier = Modifier.padding(top = 2.dp),
                    )
                }
                if (state.isModelDownloading) {
                    LinearProgressIndicator(
                        progress = { state.totalDownloadProgress.coerceIn(0f, 1f) },
                        modifier = Modifier.fillMaxWidth().padding(top = 2.dp),
                    )
                }
                if (state.needsModelDownload) {
                    OutlinedButton(
                        onClick = viewModel::downloadOfflineModels,
                        enabled = !state.isModelDownloading,
                        modifier = Modifier.padding(top = 4.dp).height(32.dp),
                    ) { Text(if (state.isModelDownloading) "下载中..." else "下载离线模型") }
                }
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Button(onClick = { memoryMonitor.markRunStarted(); viewModel.start() }, enabled = state.canStart && !state.isRunning, modifier = Modifier.weight(1f)) { Text("开始并发翻译") }
                    OutlinedButton(onClick = { memoryMonitor.markRunStopped(); viewModel.stop() }, enabled = state.isRunning, modifier = Modifier.weight(1f)) { Text("停止") }
                }
                Text("采集：${state.captureStatus}", modifier = Modifier.padding(vertical = 4.dp), style = MaterialTheme.typography.bodySmall)
            }
            Row(
                modifier = Modifier.fillMaxWidth().weight(1f),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                RuntimeBubblePane(
                    title = "在线气泡",
                    runtime = ConcurrentConversationMapper.Runtime.ONLINE,
                    rows = state.rows,
                    color = Color(0xFFE8F7F2),
                    modifier = Modifier.weight(1f),
                )
                RuntimeBubblePane(
                    title = "离线气泡",
                    runtime = ConcurrentConversationMapper.Runtime.OFFLINE,
                    rows = state.rows,
                    color = Color(0xFFFFEEE8),
                    modifier = Modifier.weight(1f),
                )
            }
        }

        if (showTtsSourceDialog) {
            ConcurrentTtsSourceDialog(
                initialSource = state.ttsSource,
                onDismiss = { showTtsSourceDialog = false },
                onConfirm = {
                    showTtsSourceDialog = false
                    viewModel.selectTtsSource(it)
                },
            )
        }
        if (showBubbleRetentionLimitDialog) {
            BubbleRetentionLimitDialog(
                initialLimit = state.bubbleRetentionLimit,
                onDismiss = { showBubbleRetentionLimitDialog = false },
                onConfirm = {
                    showBubbleRetentionLimitDialog = false
                    viewModel.setBubbleRetentionLimit(it)
                },
            )
        }
        if (showPlaybackModeDialog) {
            OneToOnePlaybackModeDialog(
                initialMode = state.playbackMode,
                onDismiss = { showPlaybackModeDialog = false },
                onConfirm = {
                    showPlaybackModeDialog = false
                    viewModel.selectPlaybackMode(it)
                },
            )
        }
    }
}

@Composable
private fun RuntimeBubblePane(
    title: String,
    runtime: ConcurrentConversationMapper.Runtime,
    rows: List<ConcurrentConversationMapper.Row>,
    color: Color,
    modifier: Modifier,
) {
    val displayRows = rows.filter { it.runtime == runtime }
    val listState = rememberLazyListState()
    LaunchedEffect(
        displayRows.size,
        displayRows.lastOrNull()?.id,
        displayRows.lastOrNull()?.asr,
        displayRows.lastOrNull()?.mt,
    ) {
        if (displayRows.isNotEmpty()) {
            // 两个 Runtime 各自滚动，始终把最新气泡留在可视区域。
            listState.scrollToItem(displayRows.lastIndex)
        }
    }
    Card(
        modifier = modifier.fillMaxHeight(),
        colors = CardDefaults.cardColors(containerColor = color.copy(alpha = .32f)),
    ) {
        Column(Modifier.fillMaxSize().padding(horizontal = 6.dp, vertical = 8.dp)) {
            Text(title, fontWeight = FontWeight.SemiBold, modifier = Modifier.padding(horizontal = 6.dp))
            LazyColumn(state = listState, modifier = Modifier.weight(1f).fillMaxWidth()) {
                items(
                    displayRows,
                    key = { it.id },
                ) { row ->
                    val bubbleColor = if (row.lane == ConcurrentConversationMapper.Lane.LEFT) {
                        Color(0xFFDDEBFF)
                    } else {
                        Color(0xFFFFE1D6)
                    }
                    Row(
                        modifier = Modifier.fillMaxWidth().padding(vertical = 4.dp),
                        horizontalArrangement = if (row.lane == ConcurrentConversationMapper.Lane.LEFT) {
                            Arrangement.Start
                        } else {
                            Arrangement.End
                        },
                    ) {
                        Card(
                            modifier = Modifier.fillMaxWidth(0.96f),
                            colors = CardDefaults.cardColors(containerColor = bubbleColor),
                        ) {
                            Column(Modifier.padding(8.dp)) {
                                Text("ASR：${row.asr}", fontSize = 8.sp, lineHeight = 10.sp)
                                Text("MT：${row.mt}", fontSize = 8.sp, lineHeight = 10.sp)
                            }
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun RuntimeCard(
    title: String,
    language: String,
    status: String,
    color: Color,
    retryEnabled: Boolean,
    retry: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val retryColor = if (retryEnabled) Color(0xFF1976D2) else Color(0xFF9EA2AD)
    val retryBackground = retryColor.copy(alpha = if (retryEnabled) .16f else .12f)
    Card(
        modifier = modifier.height(RuntimeStatusCardHeight),
        colors = CardDefaults.cardColors(containerColor = color.copy(alpha = .10f)),
    ) {
        Column(Modifier.fillMaxSize().padding(horizontal = 10.dp, vertical = 8.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(title, fontWeight = FontWeight.SemiBold, fontSize = 12.sp)
                Spacer(Modifier.weight(1f))
                OutlinedButton(
                    onClick = retry,
                    enabled = retryEnabled,
                    colors = ButtonDefaults.outlinedButtonColors(
                        containerColor = retryBackground,
                        disabledContainerColor = retryBackground,
                        contentColor = retryColor,
                        disabledContentColor = retryColor,
                    ),
                    border = BorderStroke(1.dp, retryColor),
                    modifier = Modifier.width(56.dp).height(32.dp),
                    contentPadding = PaddingValues(0.dp),
                ) { Text("重试", fontSize = 10.sp) }
            }
            Text(
                language,
                modifier = Modifier.padding(top = 2.dp),
                style = MaterialTheme.typography.bodySmall,
                fontSize = 11.sp,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Text(
                status,
                modifier = Modifier.padding(top = 1.dp),
                style = MaterialTheme.typography.bodySmall,
                fontSize = 10.sp,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
        }
    }
}

@Composable
private fun ConcurrentTtsSourceDialog(
    initialSource: ConcurrentOneToOneViewModel.TtsSource,
    onDismiss: () -> Unit,
    onConfirm: (ConcurrentOneToOneViewModel.TtsSource) -> Unit,
) {
    var source by remember(initialSource) { mutableStateOf(initialSource) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("设置 TTS 来源") },
        text = {
            Column(Modifier.fillMaxWidth()) {
                ConcurrentOneToOneViewModel.TtsSource.entries.forEach { item ->
                    Row(
                        modifier = Modifier.fillMaxWidth().padding(vertical = 4.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        RadioButton(selected = source == item, onClick = { source = item })
                        Text(item.title)
                    }
                }
            }
        },
        confirmButton = {
            Button(onClick = { onConfirm(source) }) { Text("确定") }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) { Text("取消") }
        },
    )
}
