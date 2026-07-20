package co.timekettle.translation.sample

internal data class OnlineOneToOneChannelLanguages(
    val leftLang: String,
    val rightLang: String,
)

internal object OnlineOneToOneLanguageMapping {
    fun fromDemoSelection(sourceLang: String, targetLang: String): OnlineOneToOneChannelLanguages {
        return OnlineOneToOneChannelLanguages(
            leftLang = targetLang,
            rightLang = sourceLang,
        )
    }
}
