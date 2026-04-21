package co.timekettle.translation.sample

object TranslationLanguages {

    val online = linkedMapOf(
        "zh-CN" to "🇨🇳 中文",
        "en-US" to "🇺🇸 English",
        "ja-JP" to "🇯🇵 日本語",
        "ko-KR" to "🇰🇷 한국어",
        "fr-FR" to "🇫🇷 Français",
        "es-ES" to "🇪🇸 Español",
        "ru-RU" to "🇷🇺 Русский",
        "de-DE" to "🇩🇪 Deutsch",
        "it-IT" to "🇮🇹 Italiano",
        "pt-BR" to "🇧🇷 Português",
        "ar-SA" to "🇸🇦 العربية",
        "th-TH" to "🇹🇭 ไทย",
    )

    val offline = linkedMapOf(
        "zh-CN" to "🇨🇳 中文",
        "en-US" to "🇺🇸 English",
        "ja-JP" to "🇯🇵 日本語",
        "ko-KR" to "🇰🇷 한국어",
        "fr-FR" to "🇫🇷 Français",
        "es-ES" to "🇪🇸 Español",
        "ru-RU" to "🇷🇺 Русский",
        "de-DE" to "🇩🇪 Deutsch",
        "it-IT" to "🇮🇹 Italiano",
        "ar-SA" to "🇸🇦 العربية",
        "th-TH" to "🇹🇭 ไทย",
    )

    fun displayName(code: String): String = online[code] ?: offline[code] ?: code
}
