package co.timekettle.translation.sample

import co.timekettle.translation.OnlineLanguageService
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue

@Composable
fun rememberOnlineLanguageOptions(): Map<String, String> {
    var onlineLangs by remember {
        mutableStateOf(OnlineLanguageService.getCached()?.takeIf { it.isNotEmpty() })
    }

    LaunchedEffect(Unit) {
        if (onlineLangs == null) {
            try {
                onlineLangs = OnlineLanguageService.fetch().takeIf { it.isNotEmpty() }
            } catch (_: Exception) {
            }
        }
    }

    return onlineLangs ?: TranslationLanguages.online
}
