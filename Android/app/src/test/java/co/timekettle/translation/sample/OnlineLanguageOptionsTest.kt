package co.timekettle.translation.sample

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class OnlineLanguageOptionsTest {
    @Test
    fun `mergeOnlineLanguageDefaults keeps core demo defaults when remote list is partial`() {
        val merged = mergeOnlineLanguageDefaults(
            linkedMapOf(
                "en-US" to "United States",
                "en-GB" to "United Kingdom",
            )
        )

        assertTrue("zh-CN should remain selectable for the online demo", "zh-CN" in merged)
        assertEquals("United States", merged["en-US"])
        assertEquals("United Kingdom", merged["en-GB"])
    }
}
