package co.timekettle.translation.sample

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.unit.dp

@Composable
fun TranslationStatusLine(
    statusText: String,
    modifier: Modifier = Modifier,
) {
    val isErrorStatus = statusText.contains("失败") ||
        statusText.contains("错误") ||
        statusText.contains("未授权")
    Text(
        text = "状态：$statusText",
        style = MaterialTheme.typography.bodySmall,
        color = if (isErrorStatus) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurface,
        modifier = modifier.fillMaxWidth().padding(bottom = 2.dp),
    )
}

@Composable
fun TranslationLanguageLine(
    sourceLang: String,
    targetLang: String,
    showDetailInfo: Boolean,
    onToggleDetail: () -> Unit,
    modifier: Modifier = Modifier,
    bidirectional: Boolean = true,
) {
    Row(
        modifier = modifier.fillMaxWidth().padding(bottom = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Row(
            modifier = Modifier.weight(1f).height(32.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            LanguageTextBox("语言：")
            LanguageTextBox(TranslationLanguages.displayName(sourceLang))
            LanguageArrowControl(bidirectional = bidirectional)
            LanguageTextBox(TranslationLanguages.displayName(targetLang))
        }
        TextButton(onClick = onToggleDetail) {
            Text(if (showDetailInfo) "收起" else "更多")
        }
    }
}

@Composable
private fun LanguageTextBox(text: String) {
    Box(
        modifier = Modifier.height(32.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text(text = text, style = MaterialTheme.typography.bodySmall)
    }
}

@Composable
fun TranslationDetailPanel(
    rows: List<String>,
    modifier: Modifier = Modifier,
) {
    Surface(
        modifier = modifier.fillMaxWidth().padding(bottom = 6.dp),
        tonalElevation = 1.dp,
        shape = MaterialTheme.shapes.medium,
    ) {
        Column(Modifier.padding(horizontal = 12.dp, vertical = 10.dp)) {
            rows.forEach {
                Text(it, style = MaterialTheme.typography.bodySmall)
            }
        }
    }
}

@Composable
fun TranslationStartStopButtons(
    startText: String,
    stopText: String,
    startEnabled: Boolean,
    stopEnabled: Boolean,
    onStart: () -> Unit,
    onStop: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Row(
        modifier = modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Button(
            onClick = onStart,
            enabled = startEnabled,
            modifier = Modifier.weight(1f).height(40.dp),
            colors = ButtonDefaults.buttonColors(containerColor = Color(0xFF4CAF50)),
        ) { Text(startText) }
        Button(
            onClick = onStop,
            enabled = stopEnabled,
            modifier = Modifier.weight(1f).height(40.dp),
            colors = ButtonDefaults.buttonColors(containerColor = Color(0xFFF44336)),
        ) { Text(stopText) }
    }
}

@Composable
fun LanguageArrowControl(bidirectional: Boolean = true) {
    Surface(
        modifier = Modifier
            .padding(horizontal = 6.dp)
            .size(width = 27.dp, height = 14.dp),
        color = MaterialTheme.colorScheme.primary.copy(alpha = 0.12f),
        contentColor = MaterialTheme.colorScheme.primary,
        shape = MaterialTheme.shapes.small,
    ) {
        Box(contentAlignment = Alignment.Center) {
            if (bidirectional) {
                BidirectionalLanguageArrow(color = MaterialTheme.colorScheme.primary)
            } else {
                SingleDirectionLanguageArrow(color = MaterialTheme.colorScheme.primary)
            }
        }
    }
}

@Composable
private fun BidirectionalLanguageArrow(color: Color) {
    Canvas(modifier = Modifier.size(width = 18.dp, height = 9.dp)) {
        val y = size.height / 2f
        val start = 2.5.dp.toPx()
        val end = size.width - start
        val head = 3.dp.toPx()
        val stroke = 1.75.dp.toPx()

        drawLine(color, Offset(start, y), Offset(end, y), stroke, StrokeCap.Round)
        drawLine(color, Offset(start, y), Offset(start + head, y - head * 0.7f), stroke, StrokeCap.Round)
        drawLine(color, Offset(start, y), Offset(start + head, y + head * 0.7f), stroke, StrokeCap.Round)
        drawLine(color, Offset(end, y), Offset(end - head, y - head * 0.7f), stroke, StrokeCap.Round)
        drawLine(color, Offset(end, y), Offset(end - head, y + head * 0.7f), stroke, StrokeCap.Round)
    }
}

@Composable
private fun SingleDirectionLanguageArrow(color: Color) {
    Canvas(modifier = Modifier.size(width = 18.dp, height = 9.dp)) {
        val y = size.height / 2f
        val start = 2.5.dp.toPx()
        val end = size.width - start
        val head = 3.dp.toPx()
        val stroke = 1.75.dp.toPx()

        drawLine(color, Offset(start, y), Offset(end, y), stroke, StrokeCap.Round)
        drawLine(color, Offset(end, y), Offset(end - head, y - head * 0.7f), stroke, StrokeCap.Round)
        drawLine(color, Offset(end, y), Offset(end - head, y + head * 0.7f), stroke, StrokeCap.Round)
    }
}
