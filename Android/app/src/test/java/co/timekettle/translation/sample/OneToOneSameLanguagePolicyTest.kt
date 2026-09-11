package co.timekettle.translation.sample

import co.timekettle.translation.enums.TmkRoomScenario
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class OneToOneSameLanguagePolicyTest {
    @Test
    fun onlineDifferentLanguageCodesAreAllowedInEveryRoomScenario() {
        assertTrue(
            OneToOneSameLanguagePolicy.isOnlineLanguagePairAllowed(
                sourceLang = "zh-CN",
                targetLang = "en-US",
                roomScenario = TmkRoomScenario.TRANSLATE_SPEECH_TO_SPEECH,
            ),
        )
    }

    @Test
    fun onlineSameLanguageCodeIsAllowedOnlyForRecognize() {
        assertTrue(
            OneToOneSameLanguagePolicy.isOnlineLanguagePairAllowed(
                sourceLang = "zh-CN",
                targetLang = "zh-CN",
                roomScenario = TmkRoomScenario.RECOGNIZE,
            ),
        )
        assertFalse(
            OneToOneSameLanguagePolicy.isOnlineLanguagePairAllowed(
                sourceLang = "zh-CN",
                targetLang = "zh-CN",
                roomScenario = TmkRoomScenario.TRANSLATE_SPEECH_TO_TEXT,
            ),
        )
        assertFalse(
            OneToOneSameLanguagePolicy.isOnlineLanguagePairAllowed(
                sourceLang = "zh-CN",
                targetLang = "zh-CN",
                roomScenario = TmkRoomScenario.TRANSLATE_SPEECH_TO_SPEECH,
            ),
        )
    }

    @Test
    fun offlineNormalizedSameLanguageIsAllowedOnlyForRecognize() {
        assertTrue(
            OneToOneSameLanguagePolicy.isOfflineLanguagePairAllowed(
                sourceLang = "en-US",
                targetLang = "en",
                roomScenario = TmkRoomScenario.RECOGNIZE,
            ),
        )
        assertFalse(
            OneToOneSameLanguagePolicy.isOfflineLanguagePairAllowed(
                sourceLang = "en-US",
                targetLang = "en",
                roomScenario = TmkRoomScenario.TRANSLATE_SPEECH_TO_TEXT,
            ),
        )
        assertFalse(
            OneToOneSameLanguagePolicy.isOfflineLanguagePairAllowed(
                sourceLang = "en_US",
                targetLang = "en",
                roomScenario = TmkRoomScenario.TRANSLATE_SPEECH_TO_TEXT,
            ),
        )
    }

    @Test
    fun onlineDifferentLocaleCodesRemainAllowedOutsideRecognize() {
        assertTrue(
            OneToOneSameLanguagePolicy.isOnlineLanguagePairAllowed(
                sourceLang = "en-US",
                targetLang = "en",
                roomScenario = TmkRoomScenario.TRANSLATE_SPEECH_TO_TEXT,
            ),
        )
    }

    @Test
    fun homeBlocksSameLanguagePairsForDefaultOneToOneModes() {
        assertFalse(
            isHomeOneToOneLanguagePairAllowed(
                isOneToOne = true,
                modeId = "ONLINE",
                sourceLang = "zh-CN",
                targetLang = "zh-CN",
            ),
        )
        assertFalse(
            isHomeOneToOneLanguagePairAllowed(
                isOneToOne = true,
                modeId = "OFFLINE",
                sourceLang = "en-US",
                targetLang = "en",
            ),
        )
        assertFalse(
            isHomeOneToOneLanguagePairAllowed(
                isOneToOne = true,
                modeId = "CONCURRENT_ONE_TO_ONE",
                sourceLang = "en-US",
                targetLang = "en",
            ),
        )
    }

    @Test
    fun homeKeepsValidAndNonOneToOnePairsStartable() {
        assertTrue(
            isHomeOneToOneLanguagePairAllowed(
                isOneToOne = true,
                modeId = "ONLINE",
                sourceLang = "en-US",
                targetLang = "en",
            ),
        )
        assertTrue(
            isHomeOneToOneLanguagePairAllowed(
                isOneToOne = false,
                modeId = "ONLINE",
                sourceLang = "zh-CN",
                targetLang = "zh-CN",
            ),
        )
    }
}
