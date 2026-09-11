package co.timekettle.translation.sample

import co.timekettle.translation.enums.TmkRoomScenario

/** 1v1 同语言只允许单识别，避免非识别档位请求无意义的同语言 MT。 */
internal object OneToOneSameLanguagePolicy {
    const val REQUIRES_RECOGNIZE_MESSAGE = "相同语言仅支持单识别，请先切换房间能力"

    fun isOfflineLanguagePairAllowed(
        sourceLang: String,
        targetLang: String,
        roomScenario: TmkRoomScenario,
    ): Boolean {
        val normalizedSource = normalizedOfflineLanguageCode(sourceLang)
        val normalizedTarget = normalizedOfflineLanguageCode(targetLang)
        return normalizedSource != normalizedTarget || roomScenario == TmkRoomScenario.RECOGNIZE
    }

    fun isOnlineLanguagePairAllowed(
        sourceLang: String,
        targetLang: String,
        roomScenario: TmkRoomScenario,
    ): Boolean {
        return !sourceLang.equals(targetLang, ignoreCase = true) || roomScenario == TmkRoomScenario.RECOGNIZE
    }

    private fun normalizedOfflineLanguageCode(language: String): String {
        return language.trim().substringBefore('-').substringBefore('_').lowercase()
    }
}
