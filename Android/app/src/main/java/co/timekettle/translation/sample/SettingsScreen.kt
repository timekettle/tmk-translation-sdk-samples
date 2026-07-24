package co.timekettle.translation.sample

import co.timekettle.translation.TmkTranslationSDK
import android.content.Context
import android.content.Intent
import android.widget.Toast
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.relocation.BringIntoViewRequester
import androidx.compose.foundation.relocation.bringIntoViewRequester
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.activity.compose.BackHandler
import androidx.core.content.FileProvider
import cafe.adriel.voyager.core.screen.Screen
import cafe.adriel.voyager.navigator.LocalNavigator
import cafe.adriel.voyager.navigator.currentOrThrow

import co.timekettle.offlinesdk.diagnosis.SdkDiagnosisManager
import co.timekettle.translation.config.TmkTranslationNetworkEnvironment
import co.timekettle.translation.listener.AuthCallback
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.util.UUID

private val BgColor = Color(0xFF0F1117)
private val CardColor = Color(0xFF222632)
private val BorderColor = Color(0xFF2E3345)
private val PrimaryColor = Color(0xFF6C5CE7)
private val PrimaryLight = Color(0xFFA29BFE)
private val TextColor = Color(0xFFE8E8EE)
private val TextDim = Color(0xFF8B8FA3)
private val OnlineColor = Color(0xFF00B894)
private val WarningColor = Color(0xFFFFC857)
private val DangerColor = Color(0xFFFF6B6B)

class SettingsScreen : Screen {

    @Composable
    override fun Content() {
        val navigator = LocalNavigator.currentOrThrow
        val context = LocalContext.current
        val focusManager = LocalFocusManager.current
        val keyboardController = LocalSoftwareKeyboardController.current
        val scope = rememberCoroutineScope()
        val scrollState = rememberScrollState()
        val baseURLBringIntoViewRequester = remember { BringIntoViewRequester() }
        BackHandler { navigator.pop() }

        var mockEngine by remember { mutableStateOf(false) }
        var autoRefresh by remember { mutableStateOf(true) }
        var exportingDiagnosis by remember { mutableStateOf(false) }
        var environmentExpanded by remember { mutableStateOf(false) }
        // 对齐 iOS 设置页:所有设置项(诊断/控制台/敏感词脱敏/网络环境/自定义URL 开关/URL)改动只更新 draft,
        // 一律不即时生效;点「确认并应用」才把 draft 落地(持久化 + 应用到运行时 + 重建 SDK)。
        // persisted 为已生效快照,确认成功后才 = draft;确认按钮启用条件用 draft != persisted 值比较。
        val initialConfig = remember {
            DemoDraftConfig(
                diagnosisEnabled = SdkDiagnosisManager.isEnabled(),
                consoleLogEnabled = SdkDiagnosisManager.isConsoleEnabled(),
                networkEnvironment = DemoSettingsStore.loadNetworkEnvironment(context),
                customBaseURLEnabled = DemoSettingsStore.loadCustomNetworkBaseURLEnabled(context),
                customBaseURLInput = DemoSettingsStore.loadCustomNetworkBaseURL(context)
                    ?: DemoSettingsStore.RAYNEO_NETWORK_BASE_URL,
                sensitiveWordRedactionEnabled = DemoSettingsStore.loadSensitiveWordRedactionEnabled(context),
            )
        }
        var persisted by remember { mutableStateOf(initialConfig) }
        var draft by remember { mutableStateOf(initialConfig) }
        var isApplying by remember { mutableStateOf(false) }
        var onlineEngineStatus by remember { mutableStateOf(DemoEngineStatus.CHECKING) }
        var offlineEngineStatus by remember { mutableStateOf(DemoEngineStatus.CHECKING) }
        val isCustomBaseURLValid = !draft.customBaseURLEnabled ||
            DemoSettingsStore.normalizeCustomNetworkBaseURL(draft.customBaseURLInput) != null
        // 确认按钮启用:有未应用改动 && (未开自定义URL 或 URL 合法) && 非应用中。
        val isConfirmEnabled = draft != persisted && isCustomBaseURLValid && !isApplying

        // 仅刷新引擎状态展示:不销毁 SDK,用于进入页面时呈现当前鉴权/引擎可用性。
        fun refreshEngineStatus() {
            onlineEngineStatus = DemoEngineStatus.CHECKING
            offlineEngineStatus = DemoEngineStatus.CHECKING
            runCatching {
                TmkTranslationSDK.sdkInit(context.applicationContext, SampleSdkConfig.globalConfig(context))
                TmkTranslationSDK.verifyAuth(object : AuthCallback {
                    override fun onSuccess() {
                        val snapshot = DemoEngineStatusMapper.fromAuthResult(
                            authSuccess = true,
                            offlineSupported = TmkTranslationSDK.isOfflineTranslationSupported(),
                            errorMessage = null,
                        )
                        onlineEngineStatus = snapshot.online
                        offlineEngineStatus = snapshot.offline
                    }

                    override fun onError(errorId: Int, e: Exception) {
                        val snapshot = DemoEngineStatusMapper.fromAuthResult(
                            authSuccess = false,
                            offlineSupported = false,
                            errorMessage = e.message,
                        )
                        onlineEngineStatus = snapshot.online
                        offlineEngineStatus = snapshot.offline
                    }
                })
            }.onFailure { error ->
                val snapshot = DemoEngineStatusMapper.fromAuthResult(
                    authSuccess = false,
                    offlineSupported = false,
                    errorMessage = error.message,
                )
                onlineEngineStatus = snapshot.online
                offlineEngineStatus = snapshot.offline
            }
        }

        // 确认应用设置:把 draft 落地——先应用诊断/控制台运行期开关并持久化网络设置,再 destroy +
        // 按新设置重建并鉴权,保证整条链路(含单例持有的网络组件)全部切到新环境。SDK 层 ApiRepository
        // 已改为动态派生 baseUrl,此处 destroy 是交互语义上的「显式确认重建」,与之互补而非互相依赖。
        fun applyNetworkSettings() {
            val target = draft
            isApplying = true
            onlineEngineStatus = DemoEngineStatus.CHECKING
            offlineEngineStatus = DemoEngineStatus.CHECKING
            // 诊断/控制台是运行期开关(非 globalConfig 注入),在此刻统一生效——与网络设置同受确认按钮控制。
            SdkDiagnosisManager.setEnabled(target.diagnosisEnabled)
            SdkDiagnosisManager.setConsoleEnabled(target.consoleLogEnabled)
            // 网络设置持久化,供 SampleSdkConfig.globalConfig(context) 读取后重建 SDK。
            DemoSettingsStore.saveNetworkEnvironment(context, target.networkEnvironment)
            DemoSettingsStore.saveCustomNetworkBaseURLEnabled(context, target.customBaseURLEnabled)
            if (target.customBaseURLEnabled) {
                DemoSettingsStore.saveCustomNetworkBaseURL(context, target.customBaseURLInput)
            }
            DemoSettingsStore.saveSensitiveWordRedactionEnabled(context, target.sensitiveWordRedactionEnabled)
            runCatching {
                TmkTranslationSDK.destroy()
                TmkTranslationSDK.sdkInit(context.applicationContext, SampleSdkConfig.globalConfig(context))
                TmkTranslationSDK.verifyAuth(object : AuthCallback {
                    override fun onSuccess() {
                        val snapshot = DemoEngineStatusMapper.fromAuthResult(
                            authSuccess = true,
                            offlineSupported = TmkTranslationSDK.isOfflineTranslationSupported(),
                            errorMessage = null,
                        )
                        onlineEngineStatus = snapshot.online
                        offlineEngineStatus = snapshot.offline
                        persisted = target
                        isApplying = false
                        Toast.makeText(context, "设置已应用", Toast.LENGTH_SHORT).show()
                    }

                    override fun onError(errorId: Int, e: Exception) {
                        val snapshot = DemoEngineStatusMapper.fromAuthResult(
                            authSuccess = false,
                            offlineSupported = false,
                            errorMessage = e.message,
                        )
                        onlineEngineStatus = snapshot.online
                        offlineEngineStatus = snapshot.offline
                        persisted = target
                        isApplying = false
                    }
                })
            }.onFailure { error ->
                val snapshot = DemoEngineStatusMapper.fromAuthResult(
                    authSuccess = false,
                    offlineSupported = false,
                    errorMessage = error.message,
                )
                onlineEngineStatus = snapshot.online
                offlineEngineStatus = snapshot.offline
                isApplying = false
            }
        }

        LaunchedEffect(Unit) {
            refreshEngineStatus()
        }

        Column(
            Modifier.fillMaxSize().background(BgColor)
                .pointerInput(Unit) {
                    detectTapGestures {
                        focusManager.clearFocus()
                        keyboardController?.hide()
                    }
                }
                .imePadding()
        ) {
            // 可滚动内容区:占据除底部按钮外的全部空间,内部滚动。
            Column(
                Modifier.weight(1f)
                    .fillMaxWidth()
                    .verticalScroll(scrollState)
                    .padding(horizontal = 20.dp, vertical = 16.dp)
            ) {
            Spacer(Modifier.height(24.dp))
            Text("设置", fontSize = 22.sp, fontWeight = FontWeight.Bold, color = TextColor,
                modifier = Modifier.fillMaxWidth(), textAlign = TextAlign.Center)

            Spacer(Modifier.height(28.dp))

            // SDK 配置
            SectionLabel("SDK 配置")
            SettingToggle("诊断模式", "记录详细日志用于排查问题", draft.diagnosisEnabled) {
                draft = draft.copy(diagnosisEnabled = it)
            }
            SettingToggle("控制台日志", "在 Logcat 输出日志", draft.consoleLogEnabled) {
                draft = draft.copy(consoleLogEnabled = it)
            }
            SettingToggle("敏感词脱敏", "仅在线翻译生效：对客户端可见文本启用敏感词脱敏", draft.sensitiveWordRedactionEnabled) {
                draft = draft.copy(sensitiveWordRedactionEnabled = it)
            }
            SettingRow("网络环境", "当前 SDK 请求环境") {
                Box {
                    TextButton(onClick = { environmentExpanded = true }) {
                        Text("${draft.networkEnvironment.displayName()} ▾", color = PrimaryLight, fontSize = 13.sp)
                    }
                    DropdownMenu(
                        expanded = environmentExpanded,
                        onDismissRequest = { environmentExpanded = false }
                    ) {
                        DemoSettingsStore.supportedNetworkEnvironments.forEach { environment ->
                            DropdownMenuItem(
                                text = { Text(environment.displayName()) },
                                onClick = {
                                    environmentExpanded = false
                                    draft = draft.copy(networkEnvironment = environment)
                                }
                            )
                        }
                    }
                }
            }
            SettingToggle("启用自定义URL", "开启后使用自定义 URL，关闭后使用网络环境枚举", draft.customBaseURLEnabled) { enabled ->
                draft = if (enabled &&
                    DemoSettingsStore.normalizeCustomNetworkBaseURL(draft.customBaseURLInput) == null
                ) {
                    // 打开开关但当前输入非法/为空时,回填 RayNeo 作为默认值(与旧行为一致)。
                    draft.copy(customBaseURLEnabled = true, customBaseURLInput = DemoSettingsStore.RAYNEO_NETWORK_BASE_URL)
                } else {
                    draft.copy(customBaseURLEnabled = enabled)
                }
            }
            if (draft.customBaseURLEnabled) {
                SettingRow("自定义URL", "必须是 HTTPS/HTTP 根地址，例如 RayNeo 地址") {
                    Column(horizontalAlignment = Alignment.End) {
                        OutlinedTextField(
                            value = draft.customBaseURLInput,
                            onValueChange = { value ->
                                draft = draft.copy(customBaseURLInput = value)
                            },
                            singleLine = true,
                            isError = !isCustomBaseURLValid,
                            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri),
                            modifier = Modifier
                                .widthIn(min = 220.dp, max = 280.dp)
                                .bringIntoViewRequester(baseURLBringIntoViewRequester)
                                .onFocusChanged { focusState ->
                                    if (focusState.isFocused) {
                                        scope.launch {
                                            baseURLBringIntoViewRequester.bringIntoView()
                                        }
                                    }
                                },
                            textStyle = LocalTextStyle.current.copy(fontSize = 12.sp, color = Color.White),
                            colors = OutlinedTextFieldDefaults.colors(
                                focusedTextColor = Color.White,
                                unfocusedTextColor = Color.White,
                                errorTextColor = Color.White,
                                cursorColor = PrimaryLight,
                                errorCursorColor = PrimaryLight,
                                focusedBorderColor = if (isCustomBaseURLValid) PrimaryLight else DangerColor,
                                unfocusedBorderColor = if (isCustomBaseURLValid) BorderColor else DangerColor,
                                errorBorderColor = DangerColor,
                            )
                        )
                        Spacer(Modifier.height(8.dp))
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            if (!isCustomBaseURLValid) {
                                Text("请输入形如 RayNeo 的 URL", color = DangerColor, fontSize = 11.sp)
                                Spacer(Modifier.width(8.dp))
                            }
                            TextButton(onClick = {
                                draft = draft.copy(customBaseURLInput = DemoSettingsStore.RAYNEO_NETWORK_BASE_URL)
                            }) {
                                Text("RayNeo", color = PrimaryLight, fontSize = 12.sp)
                            }
                        }
                    }
                }
            }

            Spacer(Modifier.height(24.dp))

            // 引擎状态
            SectionLabel("引擎状态")
            SettingRow("在线引擎", "LingCast + Agora RTC") {
                StatusText(onlineEngineStatus)
            }
            SettingRow("离线引擎", offlineEngineStatus.detail) {
                StatusText(offlineEngineStatus)
            }
//            SettingToggle("Mock 引擎", "开发测试用", mockEngine) { mockEngine = it }

            Spacer(Modifier.height(24.dp))

//            // 鉴权信息
//            SectionLabel("鉴权信息")
//            SettingRow("Token 状态", "有效期剩余") {
//                Text("✓ 有效", color = OnlineColor, fontSize = 12.sp)
//            }
//            SettingToggle("自动刷新", "剩余 <20% 时自动续期", autoRefresh) { autoRefresh = it }

            if (draft.diagnosisEnabled) {
                Spacer(Modifier.height(24.dp))

                // 诊断关闭时整个导出模块不渲染，避免保留空按钮占位。
                SectionLabel("诊断")
                OutlinedButton(
                    onClick = {
                        if (exportingDiagnosis) return@OutlinedButton
                        exportingDiagnosis = true
                        scope.launch {
                            runCatching {
                                exportDiagnosisZip(context)
                            }.onSuccess { zipFile ->
                                shareDiagnosisZip(context, zipFile)
                            }.onFailure { error ->
                                Toast.makeText(context, error.message ?: "诊断日志导出失败", Toast.LENGTH_SHORT).show()
                            }
                            exportingDiagnosis = false
                        }
                    },
                    modifier = Modifier.fillMaxWidth(),
                    enabled = !exportingDiagnosis,
                    shape = RoundedCornerShape(8.dp),
                    border = androidx.compose.foundation.BorderStroke(1.dp, BorderColor),
                    colors = ButtonDefaults.outlinedButtonColors(contentColor = TextColor)
                ) {
                    Text(if (exportingDiagnosis) "导出中..." else "导出诊断日志", fontSize = 12.sp)
                }
            }

            Spacer(Modifier.height(32.dp))
            Text("TmkTranslationSDK v${TmkTranslationSDK.sdkVersion}", fontSize = 11.sp, color = TextDim,
                modifier = Modifier.fillMaxWidth(), textAlign = TextAlign.Center)
            Spacer(Modifier.height(16.dp))
            } // 可滚动内容区结束

            // 确认并应用设置:固定在屏幕底部,不随内容滚动。启用条件对齐 iOS:
            // 有未应用改动(draft != persisted) && (未开自定义URL 或 URL 合法) && 非应用中。
            Button(
                onClick = { applyNetworkSettings() },
                enabled = isConfirmEnabled,
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 20.dp, vertical = 16.dp),
                shape = RoundedCornerShape(8.dp),
                colors = ButtonDefaults.buttonColors(
                    containerColor = PrimaryColor,
                    contentColor = Color.White,
                    disabledContainerColor = BorderColor,
                    disabledContentColor = TextDim,
                ),
            ) {
                Text(
                    text = when {
                        isApplying -> "应用中..."
                        draft != persisted -> "确认并应用（将重建 SDK）"
                        else -> "已应用"
                    },
                    fontSize = 13.sp,
                )
            }
        }
    }
}

/**
 * 设置页配置草稿。所有设置项改动只更新此 draft(不即时生效),点「确认并应用」才落地——
 * 对齐 iOS DemoSettingsConfig 的 draft/persisted 双态语义。
 */
private data class DemoDraftConfig(
    val diagnosisEnabled: Boolean,
    val consoleLogEnabled: Boolean,
    val networkEnvironment: TmkTranslationNetworkEnvironment,
    val customBaseURLEnabled: Boolean,
    val customBaseURLInput: String,
    val sensitiveWordRedactionEnabled: Boolean,
)

private suspend fun exportDiagnosisZip(context: Context): File = withContext(Dispatchers.IO) {
    val diagnosisDir = TmkTranslationSDK.getDiagnosisDirectory()
        ?: throw IllegalStateException("暂无可导出的诊断日志")
    val exportDir = File(context.cacheDir, "tmk_share_exports/${UUID.randomUUID()}").apply { mkdirs() }
    val outputFile = File(exportDir, "sdk_diagnosis.zip")
    DiagnosisExportUtils.zipDirectory(diagnosisDir, outputFile)
}

private fun shareDiagnosisZip(context: Context, zipFile: File) {
    val uri = FileProvider.getUriForFile(
        context,
        "${context.packageName}.fileprovider",
        zipFile
    )
    val intent = Intent(Intent.ACTION_SEND).apply {
        type = "application/zip"
        putExtra(Intent.EXTRA_STREAM, uri)
        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
    }
    context.startActivity(Intent.createChooser(intent, "导出诊断日志"))
}

@Composable
private fun StatusText(status: DemoEngineStatus) {
    Text(status.summary, color = status.color(), fontSize = 12.sp)
}

private fun DemoEngineStatus.color(): Color {
    return when (kind) {
        DemoEngineStatusKind.CHECKING -> WarningColor
        DemoEngineStatusKind.AVAILABLE -> OnlineColor
        DemoEngineStatusKind.UNAVAILABLE -> DangerColor
    }
}

private fun TmkTranslationNetworkEnvironment.displayName(): String = name

@Composable
private fun SectionLabel(text: String) {
    Text(text, fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = TextDim,
        letterSpacing = 1.sp, modifier = Modifier.padding(bottom = 8.dp))
}

@Composable
private fun SettingRow(label: String, hint: String, trailing: @Composable () -> Unit) {
    Row(
        Modifier.fillMaxWidth().padding(vertical = 14.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Column(Modifier.weight(1f)) {
            Text(label, fontSize = 14.sp, color = TextColor)
            Text(hint, fontSize = 11.sp, color = TextDim)
        }
        trailing()
    }
    HorizontalDivider(color = BorderColor, thickness = 0.5.dp)
}

@Composable
private fun SettingToggle(label: String, hint: String, checked: Boolean, onToggle: (Boolean) -> Unit) {
    SettingRow(label, hint) {
        Switch(
            checked = checked,
            onCheckedChange = onToggle,
            colors = SwitchDefaults.colors(
                checkedThumbColor = Color.White,
                checkedTrackColor = PrimaryColor,
                uncheckedThumbColor = Color.White,
                uncheckedTrackColor = BorderColor,
            )
        )
    }
}
