package co.timekettle.translation.sample

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Popup
import androidx.compose.ui.window.PopupProperties
import cafe.adriel.voyager.core.screen.Screen
import cafe.adriel.voyager.navigator.LocalNavigator
import cafe.adriel.voyager.navigator.currentOrThrow
import co.timekettle.translation.OnlineLanguageService

private val BgColor = Color(0xFF0F1117)
private val SurfaceColor = Color(0xFF1A1D27)
private val CardColor = Color(0xFF222632)
private val BorderColor = Color(0xFF2E3345)
private val PrimaryColor = Color(0xFF6C5CE7)
private val PrimaryLight = Color(0xFFA29BFE)
private val AccentColor = Color(0xFF00CEC9)
private val TextColor = Color(0xFFE8E8EE)
private val TextDim = Color(0xFF8B8FA3)
private val OnlineColor = Color(0xFF00B894)
private val OfflineColor = Color(0xFFE17055)
private val AutoColor = Color(0xFF0984E3)
private val MixColor = Color(0xFF6C5CE7)

private enum class ScenarioType(val label: String, val icon: String, val hint: String) {
    LISTEN("收听模式", "👂", "收听外语内容，实时翻译"),
    ONE_TO_ONE("一对一对话", "💬", "双人面对面，双声道分离"),
}

private data class ModeOption(
    val id: String,
    val label: String,
    val icon: String,
    val desc: String,
    val badgeColor: Color,
)

private object ModeId {
    const val ONLINE = "ONLINE"
    const val OFFLINE = "OFFLINE"
    const val AUTO = "AUTO"
    const val MIX = "MIX"
}

private val MODE_OPTIONS = listOf(
    ModeOption(ModeId.ONLINE, "在线翻译", "☁️", "云端引擎，43语种90方言", OnlineColor),
    ModeOption(ModeId.OFFLINE, "离线翻译", "📱", "本地引擎，无需网络", OfflineColor),
    ModeOption(ModeId.AUTO, "智能切换", "🔄", "断网自动降级离线", AutoColor),
    ModeOption(ModeId.MIX, "双引擎竞速", "⚡", "在线+离线择优输出", MixColor),
)

private val MODE_OPTION_BY_ID = MODE_OPTIONS.associateBy { it.id }

private val SCENARIO_MODES = mapOf(
    ScenarioType.LISTEN to listOf(ModeId.ONLINE, ModeId.OFFLINE),
    ScenarioType.ONE_TO_ONE to listOf(ModeId.ONLINE, ModeId.OFFLINE),
)

private val SCENARIO_HINTS = mapOf(
    ScenarioType.LISTEN to "支持在线/离线模式",
    ScenarioType.ONE_TO_ONE to "支持在线/离线模式",
)

class HomeScreen : Screen {

    @Composable
    override fun Content() {
        val navigator = LocalNavigator.currentOrThrow
        var scenario by remember { mutableStateOf(ScenarioType.LISTEN) }
        var modeId by remember { mutableStateOf(ModeId.ONLINE) }
        var sourceLang by remember { mutableStateOf("zh-CN") }
        var targetLang by remember { mutableStateOf("en-US") }
        val allowedModes = SCENARIO_MODES[scenario] ?: listOf(ModeId.ONLINE)
        val effectiveModeId = modeId.takeIf { it in allowedModes } ?: allowedModes.firstOrNull() ?: ModeId.ONLINE
        val effectiveMode = MODE_OPTION_BY_ID[effectiveModeId] ?: MODE_OPTIONS.first()

        // 在线语言列表：首页进来时拉取一次，有缓存就不请求
        var onlineLangs by remember { mutableStateOf(OnlineLanguageService.getCached()) }
        LaunchedEffect(Unit) {
            if (onlineLangs == null) {
                try {
                    onlineLangs = OnlineLanguageService.fetch()
                } catch (_: Exception) {}
            }
        }

        val langOptions = when (effectiveModeId) {
            ModeId.OFFLINE -> TranslationLanguages.offline
            else -> onlineLangs ?: TranslationLanguages.online
        }

        // 如果当前 mode 不在允许列表，自动切到第一个
        LaunchedEffect(scenario) {
            val allowed = SCENARIO_MODES[scenario] ?: listOf(ModeId.ONLINE)
            if (modeId !in allowed) {
                modeId = allowed.first()
            }
        }

        // 切换在线/离线模式或语言列表变化时，确保当前语言仍然在可选列表中
        LaunchedEffect(effectiveModeId, langOptions) {
            if (sourceLang !in langOptions) {
                sourceLang = langOptions.keys.first()
            }
            if (targetLang !in langOptions) {
                targetLang = langOptions.keys.firstOrNull { it != sourceLang } ?: sourceLang
            }
        }

        Column(
            modifier = Modifier
                .fillMaxSize()
                .background(BgColor)
                .padding(horizontal = 20.dp, vertical = 16.dp)
                .verticalScroll(rememberScrollState()),
        ) {
            Spacer(Modifier.height(24.dp))

            // Hero
            Text("翻译中台", fontSize = 26.sp, fontWeight = FontWeight.Bold, color = TextColor,
                modifier = Modifier.fillMaxWidth(), textAlign = TextAlign.Center)
            Text("先选场景，再选模式", fontSize = 14.sp, color = TextDim,
                modifier = Modifier.fillMaxWidth().padding(top = 4.dp), textAlign = TextAlign.Center)

            Spacer(Modifier.height(28.dp))

            // ① 使用场景
            SectionTitle("① 使用场景")
            Spacer(Modifier.height(10.dp))
            ScenarioType.entries.forEach { s ->
                ScenarioCard(s, selected = s == scenario) { scenario = s }
                Spacer(Modifier.height(8.dp))
            }

            Spacer(Modifier.height(24.dp))

            // ② 翻译模式
            Row(verticalAlignment = Alignment.CenterVertically) {
                SectionTitle("② 翻译模式")
                Spacer(Modifier.width(6.dp))
                Text("· ${SCENARIO_HINTS[scenario]}", fontSize = 11.sp, color = AccentColor)
            }
            Spacer(Modifier.height(10.dp))
            ModeGrid(allowedModes, effectiveModeId) { modeId = it }

            Spacer(Modifier.height(20.dp))

            // 语言选择
            LangRow(sourceLang, targetLang, langOptions,
                onSourceChange = { sourceLang = it },
                onTargetChange = { targetLang = it },
                onSwap = { val t = sourceLang; sourceLang = targetLang; targetLang = t }
            )

            Spacer(Modifier.height(20.dp))

            // 开始翻译
            val startLabel = "开始${effectiveMode.label}"
            Button(
                onClick = { navigator.push(resolveScreen(scenario, effectiveModeId, sourceLang, targetLang)) },
                modifier = Modifier.fillMaxWidth().height(52.dp),
                shape = RoundedCornerShape(10.dp),
                colors = ButtonDefaults.buttonColors(containerColor = Color.Transparent),
                contentPadding = PaddingValues(0.dp),
            ) {
                Box(
                    Modifier.fillMaxSize().background(
                        Brush.linearGradient(listOf(PrimaryColor, Color(0xFF8B5CF6))),
                        RoundedCornerShape(10.dp)
                    ), contentAlignment = Alignment.Center
                ) {
                    Text(
                        startLabel,
                        fontSize = 16.sp,
                        fontWeight = FontWeight.SemiBold,
                        color = Color.White,
                    )
                }
            }

            Spacer(Modifier.height(12.dp))

            // 设置入口
            TextButton(
                onClick = { navigator.push(SettingsScreen()) },
                modifier = Modifier.fillMaxWidth(),
            ) { Text("⚙️ 设置", color = TextDim, fontSize = 13.sp) }

            Spacer(Modifier.height(16.dp))
        }
    }
}

private fun resolveScreen(scenario: ScenarioType, modeId: String, srcLang: String, tgtLang: String): Screen {
    return when {
        modeId == ModeId.OFFLINE && scenario == ScenarioType.LISTEN -> OfflineListenScreen(srcLang, tgtLang)
        modeId == ModeId.OFFLINE && scenario == ScenarioType.ONE_TO_ONE -> Offline1v1Screen(srcLang, tgtLang)
        scenario == ScenarioType.ONE_TO_ONE -> DualChannelScreen(srcLang, tgtLang)
        else -> ListenModeScreen(srcLang, tgtLang)
    }
}

@Composable
private fun SectionTitle(text: String) {
    Text(text, fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = TextDim,
        letterSpacing = 1.sp)
}

@Composable
private fun ScenarioCard(s: ScenarioType, selected: Boolean, onClick: () -> Unit) {
    val border = if (selected) AccentColor else BorderColor
    val bg = if (selected) AccentColor.copy(alpha = .08f) else CardColor
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(10.dp))
            .background(bg)
            .border(1.5.dp, border, RoundedCornerShape(10.dp))
            .clickable(onClick = onClick)
            .padding(14.dp, 12.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(s.icon, fontSize = 28.sp)
            Spacer(Modifier.width(14.dp))
            Column(Modifier.weight(1f)) {
                Text(s.label, fontSize = 14.sp, fontWeight = FontWeight.SemiBold, color = TextColor)
                Text(s.hint, fontSize = 11.sp, color = TextDim)
            }
            Box(
                Modifier.size(20.dp).clip(CircleShape)
                    .background(if (selected) AccentColor else Color.Transparent)
                    .then(if (!selected) Modifier.background(Color.Transparent) else Modifier),
                contentAlignment = Alignment.Center
            ) {
                if (!selected) {
                    Box(Modifier.size(20.dp).clip(CircleShape).background(Color.Transparent)
                        .then(Modifier.background(Color.Transparent))
                    ) {
                        Box(Modifier.matchParentSize().clip(CircleShape)
                            .background(Color.Transparent)
                            .then(Modifier)) // border circle
                        Surface(Modifier.matchParentSize(), shape = CircleShape, color = Color.Transparent,
                            border = BorderStroke(2.dp, BorderColor)) {}
                    }
                } else {
                    Text("✓", fontSize = 12.sp, fontWeight = FontWeight.Bold, color = Color.White)
                }
            }
        }
    }
}

@Composable
private fun ModeGrid(allowed: List<String>, selected: String, onSelect: (String) -> Unit) {
    val rows = MODE_OPTIONS.chunked(2)
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        rows.forEach { row ->
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                row.forEach { m ->
                    val enabled = m.id in allowed
                    val isSel = m.id == selected && enabled
                    ModeCard(m, isSel, enabled, Modifier.weight(1f)) { onSelect(m.id) }
                }
                if (row.size == 1) Spacer(Modifier.weight(1f))
            }
        }
    }
}

@Composable
private fun ModeCard(m: ModeOption, selected: Boolean, enabled: Boolean, modifier: Modifier, onClick: () -> Unit) {
    val border = when { selected -> PrimaryColor; else -> BorderColor }
    val bg = if (selected) PrimaryColor.copy(alpha = .12f) else CardColor
    val shape = RoundedCornerShape(12.dp)
    Box(
        modifier = modifier
            .heightIn(min = 128.dp)
            .then(if (!enabled) Modifier.alpha(.35f) else Modifier)
            .clip(shape)
            .background(if (enabled) bg else CardColor)
            .border(2.dp, if (enabled) border else BorderColor, shape)
            .then(
                if (enabled) Modifier.clickable(onClick = onClick) else Modifier
            ),
        contentAlignment = Alignment.Center,
    ) {
        Column(
            Modifier
                .fillMaxWidth()
                .padding(14.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Text(m.icon, fontSize = 28.sp)
            Spacer(Modifier.height(4.dp))
            Text(m.label, fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = TextColor, textAlign = TextAlign.Center)
            Text(m.desc, fontSize = 10.sp, color = TextDim, textAlign = TextAlign.Center, lineHeight = 13.sp)
            Spacer(Modifier.height(6.dp))
            Surface(shape = RoundedCornerShape(4.dp), color = m.badgeColor.copy(alpha = .15f)) {
                Text(m.id, fontSize = 10.sp, fontWeight = FontWeight.SemiBold, color = m.badgeColor,
                    modifier = Modifier.padding(horizontal = 8.dp, vertical = 2.dp))
            }
        }
    }
}

@Composable
private fun LangRow(
    sourceLang: String, targetLang: String,
    options: Map<String, String>,
    onSourceChange: (String) -> Unit,
    onTargetChange: (String) -> Unit,
    onSwap: () -> Unit,
) {
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        LangSelector("源语言", sourceLang, options, onSourceChange, Modifier.weight(1f))
        Surface(
            modifier = Modifier.size(36.dp).clickable { onSwap() },
            shape = CircleShape,
            color = PrimaryColor,
        ) {
            Box(contentAlignment = Alignment.Center) {
                Text("⇄", fontSize = 16.sp, color = Color.White)
            }
        }
        LangSelector("目标语言", targetLang, options, onTargetChange, Modifier.weight(1f))
    }
}

@Composable
private fun LangSelector(label: String, selected: String, options: Map<String, String>, onChange: (String) -> Unit, modifier: Modifier) {
    var expanded by remember { mutableStateOf(false) }
    val entries = remember(options) { options.entries.toList() }

    Box(modifier = modifier.height(80.dp)) {
        Surface(
            modifier = Modifier.fillMaxSize().clickable { expanded = true },
            shape = RoundedCornerShape(10.dp),
            color = CardColor,
            border = BorderStroke(1.5.dp, if (expanded) PrimaryLight else BorderColor),
        ) {
            Column(
                Modifier.fillMaxSize().padding(14.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.Center,
            ) {
                Text(label, fontSize = 10.sp, color = TextDim, letterSpacing = .5.sp)
                Spacer(Modifier.height(4.dp))
                Text(options[selected] ?: selected, fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = TextColor)
            }
        }

        if (expanded) {
            Popup(
                alignment = Alignment.TopStart,
                offset = IntOffset(0, -350),
                onDismissRequest = { expanded = false },
                properties = PopupProperties(focusable = true),
            ) {
                Surface(
                    modifier = Modifier.width(220.dp).heightIn(max = 350.dp),
                    shape = RoundedCornerShape(8.dp),
                    shadowElevation = 8.dp,
                    color = MaterialTheme.colorScheme.surface,
                ) {
                    androidx.compose.foundation.lazy.LazyColumn {
                        items(entries.size) { idx ->
                            val (code, display) = entries[idx]
                            DropdownMenuItem(
                                text = { Text("$display ($code)", fontSize = 13.sp) },
                                onClick = { onChange(code); expanded = false }
                            )
                        }
                    }
                }
            }
        }
    }
}
