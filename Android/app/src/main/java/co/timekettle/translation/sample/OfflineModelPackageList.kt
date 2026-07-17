package co.timekettle.translation.sample

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import co.timekettle.translation.offlinemodel.TmkOfflineModelPackageInfo
import co.timekettle.translation.offlinemodel.TmkOfflineModelPackageState

@Composable
fun OfflineModelPackageList(
    packages: List<TmkOfflineModelPackageInfo>,
    modifier: Modifier = Modifier,
    // Bug3:SDK 下发的按字节总进度(0..1)。为 null 时回退到各包等权平均(非下载态/旧调用方兼容)。
    totalProgress: Float? = null,
) {
    if (packages.isEmpty()) return
    var expanded by remember { mutableStateOf(false) }
    val finishedCount = packages.count { it.state == TmkOfflineModelPackageState.READY }
    // 优先用 SDK 按字节总进度(并发准确);无则回退各包 progressValue 等权平均。
    val displayProgress = (totalProgress?.toDouble())
        ?: (packages.map { it.progressValue() }.average().takeIf { !it.isNaN() } ?: 0.0)

    Card(
        modifier = modifier.fillMaxWidth(),
        colors = CardDefaults.cardColors(containerColor = Color(0xFFF5F5F5)),
    ) {
        Column(modifier = Modifier.padding(10.dp)) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    text = "总进度：${"%.1f".format(displayProgress * 100)}%（$finishedCount/${packages.size}）",
                    style = MaterialTheme.typography.bodySmall,
                    fontWeight = FontWeight.Medium,
                    modifier = Modifier.weight(1f),
                )
                TextButton(onClick = { expanded = !expanded }) {
                    Text("离线资源详情（${packages.size}）${if (expanded) "▴" else "▾"}")
                }
            }
            LinearProgressIndicator(
                progress = { displayProgress.toFloat().coerceIn(0f, 1f) },
                modifier = Modifier.fillMaxWidth(),
            )
            if (expanded) {
                Spacer(modifier = Modifier.height(8.dp))
                packages.forEach { item ->
                    OfflineModelPackageRow(item)
                    Spacer(modifier = Modifier.height(8.dp))
                }
            }
        }
    }
}

@Composable
private fun OfflineModelPackageRow(info: TmkOfflineModelPackageInfo) {
    Column(modifier = Modifier.fillMaxWidth()) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                text = info.packageKey,
                style = MaterialTheme.typography.bodySmall,
                fontFamily = FontFamily.Monospace,
                fontWeight = FontWeight.SemiBold,
                modifier = Modifier.weight(1f),
            )
            Spacer(modifier = Modifier.width(8.dp))
            Text(
                text = info.stateText(),
                style = MaterialTheme.typography.bodySmall,
                color = Color(0xFF666666),
            )
        }
        Spacer(modifier = Modifier.height(4.dp))
        LinearProgressIndicator(
            progress = { info.progressValue().toFloat().coerceIn(0f, 1f) },
            modifier = Modifier.fillMaxWidth(),
        )
    }
}

private fun TmkOfflineModelPackageInfo.progressValue(): Double {
    return when (state) {
        TmkOfflineModelPackageState.READY -> 1.0
        TmkOfflineModelPackageState.DOWNLOADING -> {
            if (totalBytes > 0L) (downloadedBytes.toDouble() / totalBytes.toDouble()).coerceIn(0.0, 1.0) else 0.0
        }
        TmkOfflineModelPackageState.UNZIPPING -> unzipProgress.coerceIn(0.0, 1.0)
        TmkOfflineModelPackageState.NEEDS_DOWNLOAD,
        TmkOfflineModelPackageState.NEEDS_UPDATE,
        TmkOfflineModelPackageState.RESUMABLE,
        TmkOfflineModelPackageState.FAILED,
        TmkOfflineModelPackageState.CANCELLED -> 0.0
    }
}

private fun TmkOfflineModelPackageInfo.stateText(): String {
    return when (state) {
        TmkOfflineModelPackageState.READY -> "已就绪"
        TmkOfflineModelPackageState.NEEDS_DOWNLOAD -> "待下载"
        TmkOfflineModelPackageState.NEEDS_UPDATE -> "需更新"
        TmkOfflineModelPackageState.RESUMABLE -> "可续传"
        TmkOfflineModelPackageState.DOWNLOADING -> {
            val percent = progressValue() * 100
            "下载中 ${"%.1f".format(percent)}% ${formatBytes(downloadedBytes)}/${formatBytes(totalBytes)}"
        }
        TmkOfflineModelPackageState.UNZIPPING -> "解压中 ${(progressValue() * 100).toInt()}%"
        TmkOfflineModelPackageState.FAILED -> "失败"
        TmkOfflineModelPackageState.CANCELLED -> "已取消"
    }
}

private fun formatBytes(bytes: Long): String {
    if (bytes <= 0L) return "未知"
    return "%.1f MB".format(bytes.toDouble() / 1024.0 / 1024.0)
}
