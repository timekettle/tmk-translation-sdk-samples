package co.timekettle.translation.flutter

import co.timekettle.translation.model.TmkLocaleListResponse

internal fun TmkLocaleListResponse.toFlutterLanguageOptions(): List<Map<String, Any>> =
    localeOptions
        .filter { it.code.isNotBlank() }
        .map { option ->
            mapOf(
                "code" to option.code,
                "familyCode" to option.code.substringBefore("-"),
                "title" to option.displayName.ifBlank { option.code },
            )
        }
