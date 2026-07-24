package co.timekettle.translation.sample

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import co.timekettle.translation.model.BubbleRowData

private val BubbleBg = Color(0xFFF0F0F0)
private val SourceColor = Color(0xFF333333)
private val TranslatedColor = Color(0xFF1B7A3D)
private val MetaColor = Color(0xFF999999)
private val HighlightColor = Color(0xFF007AFF) // 对齐 iOS .systemBlue：TTS 播放命中的片段
private val BubbleEndLeftBorder = Color(0xFF34C759)
private val BubbleEndRightBorder = Color(0xFF007AFF)
private val TimeRangeColor = Color(0xFFE8730C) // 橙色:气泡时间段单行,醒目区别于 meta/源/译文

/**
 * 气泡时间段单行文本:仅在收到 bubbleEnd 且已聚合出 offset 时展示。
 * 时间由纳秒换算为秒,保留 3 位小数(到毫秒),形如 `⏱ offset=16.692s duration=1.600s`。
 * 否则返回 null(不占行)。离线场景无服务端 offset,bOffset 恒为 null → 永不显示(需求:离线不管)。
 */
private fun bubbleTimeRangeText(isBubbleEnded: Boolean, bOffset: Long?, bDuration: Long?): String? {
    if (!isBubbleEnded || bOffset == null) return null
    val offsetSec = nanosToSecondsText(bOffset)
    val durationSec = nanosToSecondsText(bDuration ?: 0L)
    return "⏱ offset=${offsetSec}s duration=${durationSec}s"
}

/** 纳秒 → 秒,保留 3 位小数(到毫秒)。 */
private fun nanosToSecondsText(nanos: Long): String =
    String.format(java.util.Locale.US, "%.3f", nanos / 1_000_000_000.0)

/** 气泡列表 UI */
@Composable
fun BubbleList(
    rows: List<DemoConversationBubbleSnapshot>,
    modifier: Modifier = Modifier,
    metaText: ((BubbleRowData) -> String)? = null,
    scrollOnLatestUpdate: Boolean = false,
) {
    val listState = rememberLazyListState()
    // 自动滚到底的触发 key:用轻量标识(气泡数 + 最后气泡 id + 其文本长度)代替整个 snapshot 对象。
    // 原来用 rows.lastOrNull()(data class 结构相等),每条 partial 令最后气泡文本变化都触发 LaunchedEffect
    // 重启 animateScrollToItem;长列表(数百气泡)高频动画滚动是主线程卡顿来源之一。改后仅在气泡新增或
    // 末条内容真正变化时滚动,语义(始终贴底)不变。
    val latestScrollKey: Any? = if (scrollOnLatestUpdate) {
        val last = rows.lastOrNull()?.row
        Triple(rows.size, last?.bubbleId, (last?.sourceText?.length ?: 0) + (last?.translatedText?.length ?: 0))
    } else {
        rows.size
    }
    LaunchedEffect(latestScrollKey) {
        if (rows.isNotEmpty()) listState.animateScrollToItem(rows.size - 1)
    }
    LazyColumn(state = listState, modifier = modifier, verticalArrangement = Arrangement.spacedBy(8.dp),
        contentPadding = PaddingValues(horizontal = 12.dp, vertical = 8.dp)) {
        items(rows.size, key = { index -> "${rows[index].row.sessionId}:${rows[index].row.bubbleId}" }) { index ->
            BubbleCell(rows[index], metaText?.invoke(rows[index].row))
        }
    }
}

@Composable
private fun BubbleCell(snapshot: DemoConversationBubbleSnapshot, metaText: String?) {
    val row = snapshot.row
    val isRight = row.channel.equals("right", ignoreCase = true)
    val alignment = if (isRight) Alignment.End else Alignment.Start
    val bubbleBg = if (isRight) {
        if (metaText != null) Color(0xFFE8F1FF) else Color(0xFFDCF8C6)
    } else {
        BubbleBg
    }
    val bubbleShape = RoundedCornerShape(14.dp)
    val endedBorderColor = if (isRight) BubbleEndRightBorder else BubbleEndLeftBorder
    val channelLabel = if (metaText != null) {
        null
    } else {
        when {
            row.channel.equals("left", ignoreCase = true) -> "🎙 左声道"
            row.channel.equals("right", ignoreCase = true) -> "🔊 右声道"
            else -> null
        }
    }

    Column(
        modifier = Modifier.fillMaxWidth(),
        horizontalAlignment = alignment,
    ) {
        if (channelLabel != null) {
            Text(channelLabel, fontSize = 10.sp, color = MetaColor, modifier = Modifier.padding(bottom = 2.dp))
        }
        Box(
            modifier = Modifier
                .fillMaxWidth(0.85f)
                .then(
                    if (row.isBubbleEnded) Modifier.border(1.dp, endedBorderColor, bubbleShape)
                    else Modifier
                )
                .clip(bubbleShape)
                .background(bubbleBg)
                .padding(12.dp)
        ) {
            Column {
                Text(
                    metaText ?: "sid: ${row.sessionId}  bid: ${row.bubbleId}",
                    fontSize = 10.sp, color = MetaColor, lineHeight = 13.sp,
                )
                Spacer(Modifier.height(6.dp))
                Text(
                    buildSegmentedLine(
                        label = "源语言(${row.sourceLangCode})：",
                        segments = snapshot.sourceSegments,
                        fallbackText = row.sourceText,
                        baseColor = SourceColor,
                    ),
                    fontSize = 14.sp, lineHeight = 18.sp,
                )
                Spacer(Modifier.height(4.dp))
                Text(
                    buildSegmentedLine(
                        label = "目标语言(${row.targetLangCode})：",
                        segments = snapshot.translatedSegments,
                        fallbackText = row.translatedText,
                        baseColor = TranslatedColor,
                    ),
                    fontSize = 14.sp, lineHeight = 18.sp,
                )
                // bubbleEnd 后单独一行醒目展示气泡时间段(纳秒),与源/译文和 meta 明显区分。
                val timeRangeText = bubbleTimeRangeText(row.isBubbleEnded, row.bOffset, row.bDuration)
                if (timeRangeText != null) {
                    Spacer(Modifier.height(6.dp))
                    Text(
                        timeRangeText,
                        fontSize = 13.sp, lineHeight = 17.sp, color = TimeRangeColor,
                    )
                }
            }
        }
    }
}

/**
 * 把 label + 分段文本拼成富文本：命中 TTS 高亮的片段显示为蓝色，其余为 baseColor。
 * 无分段（离线等场景）时回退到整段纯文本，保持既有展示。
 */
private fun buildSegmentedLine(
    label: String,
    segments: List<DemoConversationDisplaySegment>,
    fallbackText: String,
    baseColor: Color,
): AnnotatedString = buildAnnotatedString {
    withStyle(SpanStyle(color = baseColor)) { append(label) }
    val nonEmpty = segments.filter { it.text.isNotEmpty() }
    if (nonEmpty.isEmpty()) {
        withStyle(SpanStyle(color = baseColor)) { append(fallbackText.ifEmpty { "..." }) }
        return@buildAnnotatedString
    }
    nonEmpty.forEachIndexed { index, segment ->
        if (index > 0) {
            withStyle(SpanStyle(color = baseColor)) { append(" ") }
        }
        val color = if (segment.isHighlighted) HighlightColor else baseColor
        withStyle(SpanStyle(color = color)) { append(segment.text) }
    }
}
