package co.timekettle.translation.sample

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.activity.compose.BackHandler
import cafe.adriel.voyager.core.screen.Screen
import cafe.adriel.voyager.navigator.LocalNavigator
import cafe.adriel.voyager.navigator.currentOrThrow

import co.timekettle.offlinesdk.diagnosis.SdkDiagnosisManager

private val BgColor = Color(0xFF0F1117)
private val CardColor = Color(0xFF222632)
private val BorderColor = Color(0xFF2E3345)
private val PrimaryColor = Color(0xFF6C5CE7)
private val PrimaryLight = Color(0xFFA29BFE)
private val TextColor = Color(0xFFE8E8EE)
private val TextDim = Color(0xFF8B8FA3)
private val OnlineColor = Color(0xFF00B894)

class SettingsScreen : Screen {

    @Composable
    override fun Content() {
        val navigator = LocalNavigator.currentOrThrow
        BackHandler { navigator.pop() }

        var diagnosisEnabled by remember { mutableStateOf(SdkDiagnosisManager.isEnabled()) }
        var consoleEnabled by remember { mutableStateOf(SdkDiagnosisManager.isConsoleEnabled()) }
        var mockEngine by remember { mutableStateOf(false) }
        var autoRefresh by remember { mutableStateOf(true) }

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
//            SettingRow("网络环境", "当前：Test") {
//                Text("TEST ▾", color = PrimaryLight, fontSize = 13.sp)
//            }

            Spacer(Modifier.height(24.dp))

            // 引擎状态
            SectionLabel("引擎状态")
            SettingRow("在线引擎", "LingCast + Agora RTC") {
                Text("✓ 可用", color = OnlineColor, fontSize = 12.sp)
            }
//            SettingRow("离线引擎", "已下载语言包") {
//                Text("✓ 可用", color = OnlineColor, fontSize = 12.sp)
//            }
//            SettingToggle("Mock 引擎", "开发测试用", mockEngine) { mockEngine = it }

            Spacer(Modifier.height(24.dp))

//            // 鉴权信息
//            SectionLabel("鉴权信息")
//            SettingRow("Token 状态", "有效期剩余") {
//                Text("✓ 有效", color = OnlineColor, fontSize = 12.sp)
//            }
//            SettingToggle("自动刷新", "剩余 <20% 时自动续期", autoRefresh) { autoRefresh = it }

            Spacer(Modifier.height(24.dp))

//            // 诊断
//            SectionLabel("诊断")
//            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
//                OutlinedButton(
//                    onClick = {},
//                    modifier = Modifier.weight(1f),
//                    shape = RoundedCornerShape(8.dp),
//                    border = androidx.compose.foundation.BorderStroke(1.dp, BorderColor),
//                    colors = ButtonDefaults.outlinedButtonColors(contentColor = TextColor)
//                ) { Text("导出 SDK 日志", fontSize = 12.sp) }
//                OutlinedButton(
//                    onClick = {},
//                    modifier = Modifier.weight(1f),
//                    shape = RoundedCornerShape(8.dp),
//                    border = androidx.compose.foundation.BorderStroke(1.dp, BorderColor),
//                    colors = ButtonDefaults.outlinedButtonColors(contentColor = TextColor)
//                ) { Text("导出工作流日志", fontSize = 12.sp) }
//            }

            Spacer(Modifier.height(32.dp))
            Text("TmkTranslationSDK v1.0.0", fontSize = 11.sp, color = TextDim,
                modifier = Modifier.fillMaxWidth(), textAlign = TextAlign.Center)
            Spacer(Modifier.height(16.dp))
        }
    }
}

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
