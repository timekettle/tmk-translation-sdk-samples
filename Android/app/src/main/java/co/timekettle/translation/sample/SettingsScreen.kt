package co.timekettle.translation.sample

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.activity.compose.BackHandler
import cafe.adriel.voyager.core.screen.Screen
import cafe.adriel.voyager.navigator.LocalNavigator
import cafe.adriel.voyager.navigator.currentOrThrow

import co.timekettle.offlinesdk.diagnosis.SdkDiagnosisManager
import co.timekettle.translation.TmkTranslationSDK
import co.timekettle.translation.config.TmkTranslationNetworkEnvironment
import co.timekettle.translation.listener.AuthCallback

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
        BackHandler { navigator.pop() }

        var diagnosisEnabled by remember { mutableStateOf(SdkDiagnosisManager.isEnabled()) }
        var consoleEnabled by remember { mutableStateOf(SdkDiagnosisManager.isConsoleEnabled()) }
        var environmentExpanded by remember { mutableStateOf(false) }
        var networkEnvironment by remember { mutableStateOf(DemoSettingsStore.loadNetworkEnvironment(context)) }
        var onlineEngineStatus by remember { mutableStateOf(DemoEngineStatus.CHECKING) }
        var offlineEngineStatus by remember { mutableStateOf(DemoEngineStatus.CHECKING) }

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

        LaunchedEffect(Unit) {
            refreshEngineStatus()
        }

        Column(
            Modifier.fillMaxSize().background(BgColor)
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 20.dp, vertical = 16.dp)
        ) {
            Spacer(Modifier.height(24.dp))
            Text("设置", fontSize = 22.sp, fontWeight = FontWeight.Bold, color = TextColor,
                modifier = Modifier.fillMaxWidth(), textAlign = TextAlign.Center)

            Spacer(Modifier.height(28.dp))

            // SDK 配置
            SectionLabel("SDK 配置")
            SettingToggle("诊断模式", "记录详细日志用于排查问题", diagnosisEnabled) {
                diagnosisEnabled = it
                SdkDiagnosisManager.setEnabled(it)
            }
            SettingToggle("控制台日志", "在 Logcat 输出日志", consoleEnabled) {
                consoleEnabled = it
                SdkDiagnosisManager.setConsoleEnabled(it)
            }
            SettingRow("网络环境", "当前 SDK 请求环境") {
                Box {
                    TextButton(onClick = { environmentExpanded = true }) {
                        Text("${networkEnvironment.displayName()} ▾", color = PrimaryLight, fontSize = 13.sp)
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
                                    networkEnvironment = environment
                                    DemoSettingsStore.saveNetworkEnvironment(context, environment)
                                    refreshEngineStatus()
                                }
                            )
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

            // 诊断日志导出依赖 FileProvider，对外 samples 不暴露该诊断面，故省略导出入口。

            Spacer(Modifier.height(32.dp))
            Text(settingsSdkVersionLabel(TmkTranslationSDK.sdkVersion), fontSize = 11.sp, color = TextDim,
                modifier = Modifier.fillMaxWidth(), textAlign = TextAlign.Center)
            Spacer(Modifier.height(16.dp))
        }
    }
}

internal fun settingsSdkVersionLabel(sdkVersion: String): String = "TmkTranslationSDK v$sdkVersion"

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
