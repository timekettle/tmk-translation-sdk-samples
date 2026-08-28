package co.timekettle.translation.sample

internal data class OnlineOneToOneChannelLanguages(
    val leftLang: String,
    val rightLang: String,
)

internal object OnlineOneToOneLanguageMapping {
    fun fromDemoSelection(sourceLang: String, targetLang: String): OnlineOneToOneChannelLanguages {
        return OnlineOneToOneChannelLanguages(
            // 首页的一对一选择仍以 source/target 展示；一对一 Demo 内部明确保存左右路。
            leftLang = targetLang,
            rightLang = sourceLang,
        )
    }

    fun fromLeftRight(leftLang: String, rightLang: String): OnlineOneToOneChannelLanguages =
        OnlineOneToOneChannelLanguages(leftLang = leftLang, rightLang = rightLang)
}
