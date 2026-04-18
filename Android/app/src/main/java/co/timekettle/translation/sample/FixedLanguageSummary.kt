package co.timekettle.translation.sample

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp

@Composable
fun FixedLanguageSummary(
    leftLabel: String,
    leftLang: String,
    rightLabel: String,
    rightLang: String,
    modifier: Modifier = Modifier,
) {
    Row(
        modifier = modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        FixedLanguageCard(
            label = leftLabel,
            value = TranslationLanguages.displayName(leftLang),
            modifier = Modifier.weight(1f),
        )
        FixedLanguageCard(
            label = rightLabel,
            value = TranslationLanguages.displayName(rightLang),
            modifier = Modifier.weight(1f),
        )
    }
}

@Composable
private fun FixedLanguageCard(
    label: String,
    value: String,
    modifier: Modifier = Modifier,
) {
    Surface(modifier = modifier, tonalElevation = 1.dp) {
        Column(modifier = Modifier.padding(horizontal = 12.dp, vertical = 10.dp)) {
            Text(text = label, style = MaterialTheme.typography.labelSmall)
            Text(text = value, style = MaterialTheme.typography.bodyMedium)
        }
    }
}
