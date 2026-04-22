package co.timekettle.translation.flutter

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith

internal class SupportedLanguagesServiceTest {
    @Test
    fun buildOnlineLanguagesUrl_joinsBasePathAndQueryParameters() {
        val url = SupportedLanguagesService.buildOnlineLanguagesUrl(
            baseUrl = "https://tmk-translation-test.timekettle.net/",
            uiLocales = listOf("zh-CN"),
            version = "v3",
        )

        assertEquals(
            "https://tmk-translation-test.timekettle.net/apis/app/config/locales?ui_locales=zh-CN&flat&version=v3",
            url.toString(),
        )
    }

    @Test
    fun buildOnlineLanguagesUrl_normalizesLegacyApisBaseUrlInput() {
        val url = SupportedLanguagesService.buildOnlineLanguagesUrl(
            baseUrl = "https://tmk-translation-test.timekettle.net/apis/",
            uiLocales = listOf("zh-CN"),
            version = "v3",
        )

        assertEquals(
            "https://tmk-translation-test.timekettle.net/apis/app/config/locales?ui_locales=zh-CN&flat&version=v3",
            url.toString(),
        )
    }

    @Test
    fun parseOnlineLanguagesResponse_flattensWrappedPayload() {
        val items = SupportedLanguagesService.parseOnlineLanguagesResponse(
            """
            {
              "code": 0,
              "message": "success",
              "data": {
                "version": "v1",
                "languages": [
                  {
                    "code": "en",
                    "nativeLang": "English",
                    "uiLang": "英语",
                    "data": [
                      {
                        "code": "en-US",
                        "nativeLang": "English",
                        "uiLang": "英语"
                      }
                    ]
                  },
                  {
                    "code": "zh-CN",
                    "nativeLang": "中文",
                    "uiLang": "中文",
                    "data": []
                  }
                ]
              }
            }
            """.trimIndent(),
        )

        assertEquals(
            listOf(
                mapOf("code" to "en-US", "familyCode" to "en", "title" to "英语"),
                mapOf("code" to "zh-CN", "familyCode" to "zh", "title" to "中文"),
            ),
            items,
        )
    }

    @Test
    fun parseOnlineLanguagesResponse_throwsWhenApiCodeIsNotSuccess() {
        assertFailsWith<java.io.IOException> {
            SupportedLanguagesService.parseOnlineLanguagesResponse(
                """{"code":401,"message":"unauthorized","data":{}}""",
            )
        }
    }
}
