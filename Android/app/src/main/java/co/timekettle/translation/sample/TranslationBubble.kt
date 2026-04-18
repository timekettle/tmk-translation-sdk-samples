package co.timekettle.translation.sample

import androidx.compose.foundation.background
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
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import co.timekettle.translation.model.BubbleRowData

private val BubbleBg = Color(0xFFF0F0F0)
private val SourceColor = Color(0xFF333333)
private val TranslatedColor = Color(0xFF1B7A3D)
private val MetaColor = Color(0xFF999999)

/** 气泡列表 UI */
@Composable
fun BubbleList(rows: List<BubbleRowData>, modifier: Modifier = Modifier) {
    val listState = rememberLazyListState()
    LaunchedEffect(rows.size) {
        if (rows.isNotEmpty()) listState.animateScrollToItem(rows.size - 1)
    }
    LazyColumn(state = listState, modifier = modifier, verticalArrangement = Arrangement.spacedBy(8.dp),
        contentPadding = PaddingValues(horizontal = 12.dp, vertical = 8.dp)) {
        items(rows.size, key = { index -> "${rows[index].sessionId}:${rows[index].bubbleId}" }) { index ->
            BubbleCell(rows[index])
        }
    }
}

@Composable
private fun BubbleCell(row: BubbleRowData) {
    val isRight = row.channel.equals("right", ignoreCase = true)
    val alignment = if (isRight) Alignment.End else Alignment.Start
    val bubbleBg = if (isRight) Color(0xFFDCF8C6) else BubbleBg
    val channelLabel = when {
        row.channel.equals("left", ignoreCase = true) -> "🎙 左声道"
        row.channel.equals("right", ignoreCase = true) -> "🔊 右声道"
        else -> null
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
                .clip(RoundedCornerShape(14.dp))
                .background(bubbleBg)
                .padding(12.dp)
        ) {
            Column {
                Text(
                    "sid: ${row.sessionId}  bid: ${row.bubbleId}",
                    fontSize = 10.sp, color = MetaColor, lineHeight = 13.sp,
                )
                Spacer(Modifier.height(6.dp))
                val src = row.sourceText.ifEmpty { "..." }
                Text("源语言(${row.sourceLangCode})：$src", fontSize = 14.sp, color = SourceColor, lineHeight = 18.sp)
                Spacer(Modifier.height(4.dp))
                val tgt = row.translatedText.ifEmpty { "..." }
                Text("目标语言(${row.targetLangCode})：$tgt", fontSize = 14.sp, color = TranslatedColor, lineHeight = 18.sp)
            }
        }
    }
}
