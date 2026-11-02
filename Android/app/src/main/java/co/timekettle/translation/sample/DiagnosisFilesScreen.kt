package co.timekettle.translation.sample

import co.timekettle.translation.sample.SampleSdkConfig

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import cafe.adriel.voyager.core.screen.Screen
import cafe.adriel.voyager.navigator.LocalNavigator
import cafe.adriel.voyager.navigator.currentOrThrow
import java.text.DateFormat
import java.util.Date

/** 页面拥有导航/加载状态；生命周期取消旧请求，文件 I/O 全由后台 service 承担。 */
class DiagnosisFilesScreen : Screen {
    @Composable
    override fun Content() {
        val navigator = LocalNavigator.currentOrThrow
        DiagnosisFilesContent(SampleSdkConfig::appliedDiagnosisRootDirectory) { navigator.pop() }
    }
}

@Composable
internal fun DiagnosisFilesContent(rootProvider: () -> java.io.File?, onBack: () -> Unit) {
        val browser = remember { DemoDiagnosisBrowser() }
        var relativePath by remember { mutableStateOf("") }
        var refresh by remember { mutableIntStateOf(0) }
        var loading by remember { mutableStateOf(true) }
        var snapshot by remember { mutableStateOf<DemoDiagnosisSnapshot?>(null) }
        val formatter = remember { DateFormat.getDateTimeInstance(DateFormat.SHORT, DateFormat.MEDIUM) }
        fun back() {
            if (relativePath.isEmpty()) onBack()
            else relativePath = relativePath.substringBeforeLast('/', "")
        }
        BackHandler { back() }
        val appliedRoot = rootProvider()
        LaunchedEffect(appliedRoot?.path, relativePath, refresh) {
            loading = true
            if (snapshot?.rootPath != null && snapshot?.rootPath != appliedRoot?.absolutePath && relativePath.isNotEmpty()) {
                relativePath = ""
                return@LaunchedEffect
            }
            val root = appliedRoot
            val result = browser.load(root, relativePath)
            // 根目录切换后，旧目录请求不得覆盖新 SDK 的页面状态。
            if (root?.path != rootProvider()?.path) {
                relativePath = ""
                refresh++
            } else {
                snapshot = result
                loading = false
            }
        }
        Column(Modifier.fillMaxSize().background(Color(0xFF0F1117)).padding(16.dp)) {
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                TextButton(onClick = { back() }) { Text(if (relativePath.isEmpty()) "返回设置" else "上级目录") }
                TextButton(onClick = { refresh++ }) { Text("刷新") }
            }
            Spacer(Modifier.height(12.dp))
            val totalUsageText = if (loading) "统计中…" else snapshot?.totalBytes?.let(::formatDiagnosisBytes) ?: "暂不可用"
            val savedSessionsText = if (loading) "统计中…" else snapshot?.savedSessionCount?.let { "$it 次" } ?: "暂不可用"
            Text("诊断总占用：$totalUsageText", color = Color.White, fontSize = 13.sp)
            Text("已保存对话：$savedSessionsText", color = Color.LightGray, fontSize = 13.sp)
            Spacer(Modifier.height(8.dp))
            Text("当前/最后已应用根目录：${snapshot?.rootPath ?: "尚未应用"}", color = Color(0xFFA29BFE), fontSize = 12.sp)
            Text("当前目录：/${relativePath}", color = Color.LightGray, fontSize = 12.sp)
            Text("只读浏览；符号链接不跟随", color = Color.Gray, fontSize = 11.sp)
            Spacer(Modifier.height(12.dp))
            when {
                loading -> CircularProgressIndicator()
                snapshot?.state != DemoDiagnosisDirectoryState.READY ->
                    Text(snapshot?.message ?: "读取失败，可手动刷新", color = Color(0xFFFFC857))
                else -> {
                    snapshot?.message?.let { Text(it, color = Color(0xFFFFC857), fontSize = 12.sp) }
                    if (snapshot!!.entries.isEmpty()) Text("目录为空", color = Color.LightGray)
                    LazyColumn(Modifier.weight(1f)) {
                        items(snapshot!!.entries, key = { it.relativePath }) { entry ->
                            Column(Modifier.fillMaxWidth().clickable(enabled = entry.kind == DemoDiagnosisEntryKind.DIRECTORY) {
                                relativePath = entry.relativePath
                            }.padding(vertical = 6.dp)) {
                                val kind = when (entry.kind) {
                                    DemoDiagnosisEntryKind.DIRECTORY -> "目录"
                                    DemoDiagnosisEntryKind.FILE -> "文件"
                                    DemoDiagnosisEntryKind.SYMBOLIC_LINK -> "符号链接（不跟随）"
                                    DemoDiagnosisEntryKind.OTHER -> "其他"
                                }
                                Text(entry.name, color = if (entry.kind == DemoDiagnosisEntryKind.DIRECTORY) Color(0xFF64B5F6) else Color.White, fontSize = 15.sp)
                                Text("$kind · ${entry.bytes?.let(::formatDiagnosisBytes) ?: "大小暂不可用"}", color = Color.LightGray, fontSize = 12.sp)
                                Text("修改：${formatter.format(Date(entry.modifiedAtMillis))}", color = Color.Gray, fontSize = 11.sp)
                            }
                            HorizontalDivider(color = Color(0xFF2E3345))
                        }
                    }
                }
            }
        }
}

internal fun formatDiagnosisDirectoryTitle(root: java.io.File?, relativePath: String): String {
    if (root == null) return "诊断目录"
    val name = if (relativePath.isEmpty()) root.name else java.io.File(relativePath).name
    return "当前目录：$name"
}

private fun formatDiagnosisBytes(bytes: Long): String = when {
    bytes < 1024 -> "$bytes 字节"
    bytes < 1024L * 1024L -> String.format(java.util.Locale.US, "%.2f KiB（%d 字节）", bytes / 1024.0, bytes)
    bytes < 1024L * 1024L * 1024L -> String.format(java.util.Locale.US, "%.2f MiB（%d 字节）", bytes / (1024.0 * 1024.0), bytes)
    else -> String.format(java.util.Locale.US, "%.2f GiB（%d 字节）", bytes / (1024.0 * 1024.0 * 1024.0), bytes)
}
