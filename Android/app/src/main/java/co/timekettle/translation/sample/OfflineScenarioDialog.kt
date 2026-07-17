package co.timekettle.translation.sample

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import co.timekettle.translation.enums.TmkRoomScenario

/**
 * 离线能力档位选项(三档对齐在线,照抄 [OnlineRoomScenarioOption] 三选项结构)。
 */
enum class OfflineScenarioOption(
    val title: String,
    val roomScenario: TmkRoomScenario,
) {
    SPEECH_TO_SPEECH("语音到语音", TmkRoomScenario.TRANSLATE_SPEECH_TO_SPEECH),
    RECOGNIZE("单识别", TmkRoomScenario.RECOGNIZE),
    SPEECH_TO_TEXT("语音到文本", TmkRoomScenario.TRANSLATE_SPEECH_TO_TEXT);

    /** 该档位是否需要下载/加载 MT 模型。 */
    val needMt: Boolean get() = roomScenario.needsMt

    /** 该档位是否需要下载/加载 TTS 模型。 */
    val needTts: Boolean get() = roomScenario.needsTts

    companion object {
        val defaultOption: OfflineScenarioOption = SPEECH_TO_SPEECH
    }
}

@Composable
fun OfflineScenarioDialog(
    title: String,
    initialOption: OfflineScenarioOption,
    onDismiss: () -> Unit,
    onConfirm: (OfflineScenarioOption) -> Unit,
) {
    var option by remember(initialOption) { mutableStateOf(initialOption) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(title) },
        text = {
            Column(Modifier.fillMaxWidth()) {
                OfflineScenarioOption.entries.forEach { item ->
                    OfflineScenarioRow(item, option) { option = it }
                }
            }
        },
        confirmButton = {
            Button(onClick = { onConfirm(option) }) {
                Text("确定")
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) {
                Text("取消")
            }
        },
    )
}

@Composable
private fun OfflineScenarioRow(
    option: OfflineScenarioOption,
    selected: OfflineScenarioOption,
    onSelect: (OfflineScenarioOption) -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        RadioButton(
            selected = selected == option,
            onClick = { onSelect(option) },
        )
        Text(option.title)
    }
}

/**
 * 切语言/升档前就绪预检未通过时,待下载模型的提示信息(Bug2)。
 *
 * @param sourceLang 目标源语言(BCP-47)
 * @param targetLang 目标目标语言(BCP-47)
 * @param targetScenario 触发下载的目标档位(升档=目标档位;切语言=当前档位不变)。
 *   downloadModels 按它取 needMt/needTts 下差量包,文案取它的 title——UI 档位 _scenarioOption 在升档真正成功前不改。
 * @param description 人类可读的待下载说明(语言对 + 档位)
 * @param upgrade true=升档触发,false=切语言触发(仅用于日志/文案区分)
 */
data class PendingDownloadInfo(
    val sourceLang: String,
    val targetLang: String,
    val targetScenario: OfflineScenarioOption,
    val description: String,
    val upgrade: Boolean = false,
) {
    /** 触发下载的档位标题(如"语音到语音"),由目标档位派生。 */
    val scenarioTitle: String get() = targetScenario.title
}

/**
 * 模型未就绪确认弹窗(Bug2):复用 [OfflineScenarioDialog] 的 AlertDialog 模板风格,
 * 列出待下载语言/档位,由 [PendingDownloadInfo] 驱动。下载→[onConfirm],取消→[onDismiss]。
 */
@Composable
fun OfflineModelDownloadPromptDialog(
    info: PendingDownloadInfo,
    onConfirm: () -> Unit,
    onDismiss: () -> Unit,
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("模型未就绪") },
        text = {
            Column(Modifier.fillMaxWidth()) {
                Text(info.description)
            }
        },
        confirmButton = {
            Button(onClick = onConfirm) {
                Text("下载")
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) {
                Text("取消")
            }
        },
    )
}
