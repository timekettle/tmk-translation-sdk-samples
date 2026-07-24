package co.timekettle.translation.sample

import org.junit.Assert.assertEquals
import org.junit.Test

class OnlineOneToOneLanguageMappingTest {
    @Test
    fun fromDemoSelection_mapsTargetToLeftAndSourceToRight() {
        val languages = OnlineOneToOneLanguageMapping.fromDemoSelection(
            sourceLang = "zh-CN",
            targetLang = "en-US",
        )

        assertEquals("en-US", languages.leftLang)
        assertEquals("zh-CN", languages.rightLang)
    }
}
