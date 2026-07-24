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
import co.timekettle.translation.enums.TmkOfflineAudioChannelMode
import co.timekettle.sdk.common.models.SpeakerGender

@Composable
fun OfflineListenSpeakerDialog(
    initialGender: SpeakerGender,
    onDismiss: () -> Unit,
    onConfirm: (SpeakerGender) -> Unit,
) {
    var gender by remember(initialGender) { mutableStateOf(initialGender) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("设置音色") },
        text = {
            Column(Modifier.fillMaxWidth()) {
                SpeakerGenderRow("女声", SpeakerGender.FEMALE, gender) { gender = it }
                SpeakerGenderRow("男声", SpeakerGender.MALE, gender) { gender = it }
            }
        },
        confirmButton = {
            Button(onClick = { onConfirm(gender) }) {
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
fun Offline1v1SpeakerDialog(
    initialLeftGender: SpeakerGender,
    initialRightGender: SpeakerGender,
    onDismiss: () -> Unit,
    onConfirm: (SpeakerGender, SpeakerGender) -> Unit,
) {
    var leftGender by remember(initialLeftGender) { mutableStateOf(initialLeftGender) }
    var rightGender by remember(initialRightGender) { mutableStateOf(initialRightGender) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("设置音色") },
        text = {
            Column(Modifier.fillMaxWidth()) {
                Text("左声道")
                SpeakerGenderRow("女声", SpeakerGender.FEMALE, leftGender) { leftGender = it }
                SpeakerGenderRow("男声", SpeakerGender.MALE, leftGender) { leftGender = it }
                Text("右声道", modifier = Modifier.padding(top = 12.dp))
                SpeakerGenderRow("女声", SpeakerGender.FEMALE, rightGender) { rightGender = it }
                SpeakerGenderRow("男声", SpeakerGender.MALE, rightGender) { rightGender = it }
            }
        },
        confirmButton = {
            Button(onClick = { onConfirm(leftGender, rightGender) }) {
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
fun Offline1v1ChannelModeDialog(
    initialMode: TmkOfflineAudioChannelMode,
    onDismiss: () -> Unit,
    onConfirm: (TmkOfflineAudioChannelMode) -> Unit,
) {
    var mode by remember(initialMode) { mutableStateOf(initialMode) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("设置通道模式") },
        text = {
            Column(Modifier.fillMaxWidth()) {
                // STEREO=标准(传立体声/收立体声混合);MONO=低延迟(左右分别推、各自声道返回)。
                TtsOutputModeRow("标准模式（传立体声，收立体声）", TmkOfflineAudioChannelMode.STEREO, mode) { mode = it }
                TtsOutputModeRow("低延迟模式（左右分别推，各自声道返回）", TmkOfflineAudioChannelMode.MONO, mode) { mode = it }
            }
        },
        confirmButton = {
            Button(onClick = { onConfirm(mode) }) {
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
private fun SpeakerGenderRow(
    label: String,
    gender: SpeakerGender,
    selected: SpeakerGender,
    onSelected: (SpeakerGender) -> Unit,
) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        RadioButton(
            selected = selected == gender,
            onClick = { onSelected(gender) },
        )
        Text(label)
    }
}

@Composable
private fun TtsOutputModeRow(
    label: String,
    mode: TmkOfflineAudioChannelMode,
    selected: TmkOfflineAudioChannelMode,
    onSelected: (TmkOfflineAudioChannelMode) -> Unit,
) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        RadioButton(
            selected = selected == mode,
            onClick = { onSelected(mode) },
        )
        Text(label)
    }
}
