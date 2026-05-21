package co.timekettle.translation.sample

object TranslationLanguages {

    val online = linkedMapOf(
        "zh-CN" to "🇨🇳 中文",
        "en-US" to "🇺🇸 英语",
        "ja-JP" to "🇯🇵 日语",
        "ko-KR" to "🇰🇷 韩语",
        "fr-FR" to "🇫🇷 法语",
        "es-ES" to "🇪🇸 西班牙语",
        "ru-RU" to "🇷🇺 俄语",
        "de-DE" to "🇩🇪 德语",
        "it-IT" to "🇮🇹 意大利语",
        "pt-BR" to "🇧🇷 葡萄牙语",
        "ar-SA" to "🇸🇦 阿拉伯语",
        "th-TH" to "🇹🇭 泰语",
    )

    val offline = linkedMapOf(
        "zh-CN" to "🇨🇳 中文",
        "en-US" to "🇺🇸 英语",
        "ja-JP" to "🇯🇵 日语",
        "ko-KR" to "🇰🇷 韩语",
        "fr-FR" to "🇫🇷 法语",
        "es-ES" to "🇪🇸 西班牙语",
        "ru-RU" to "🇷🇺 俄语",
        "de-DE" to "🇩🇪 德语",
        "it-IT" to "🇮🇹 意大利语",
        "ar-SA" to "🇸🇦 阿拉伯语",
        "th-TH" to "🇹🇭 泰语",
    )

    fun displayName(code: String): String = online[code] ?: offline[code] ?: code
}
