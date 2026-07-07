package co.timekettle.translation.flutter

import co.timekettle.translation.model.TmkLocaleItem
import co.timekettle.translation.model.TmkLocaleLanguage
import co.timekettle.translation.model.TmkLocaleListResponse
import kotlin.test.Test
import kotlin.test.assertEquals

internal class SupportedLanguagesMapperTest {
    @Test
    fun toFlutterLanguageOptions_mapsSdkLocaleOptions() {
        val response = TmkLocaleListResponse(
            "v1",
            listOf(
                TmkLocaleLanguage(
                    "zh",
                    "中文",
                    listOf(TmkLocaleItem("zh-CN", "中文")),
                ),
                TmkLocaleLanguage(
                    "en",
                    "English",
                    listOf(TmkLocaleItem("en-US", "English")),
                ),
            ),
        )

        assertEquals(
            listOf(
                mapOf("code" to "zh-CN", "familyCode" to "zh", "title" to "中文"),
                mapOf("code" to "en-US", "familyCode" to "en", "title" to "English"),
            ),
            response.toFlutterLanguageOptions(),
        )
    }

    @Test
    fun toFlutterLanguageOptions_usesCodeWhenDisplayNameIsBlank() {
        val response = TmkLocaleListResponse(
            "v1",
            listOf(
                TmkLocaleLanguage(
                    "en",
                    "",
                    listOf(TmkLocaleItem("en-US", "")),
                ),
            ),
        )

        assertEquals(
            listOf(mapOf("code" to "en-US", "familyCode" to "en", "title" to "en-US")),
            response.toFlutterLanguageOptions(),
        )
    }
}
