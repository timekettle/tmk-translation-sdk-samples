package co.timekettle.translation.sample

import org.junit.Assert.assertEquals
import org.junit.Test

class OnlineConversationErrorPromptsTest {
    @Test
    fun fromCode_httpUnauthorized_promptsForReauthentication() {
        val prompt = OnlineConversationErrorPrompts.fromCode(
            code = 2_002_401,
            message = "token expired",
        )

        assertEquals("http_auth_2002401", prompt?.id)
        assertEquals("鉴权已失效", prompt?.title)
        assertEquals("重新鉴权", prompt?.restartText)
    }

    @Test
    fun fromCode_httpForbidden_promptsForReauthentication() {
        val prompt = OnlineConversationErrorPrompts.fromCode(
            code = 2_002_403,
            message = "permission denied",
        )

        assertEquals("http_auth_2002403", prompt?.id)
        assertEquals("鉴权已失效", prompt?.title)
        assertEquals("重新鉴权", prompt?.restartText)
    }

    @Test
    fun fromCode_httpClientError_promptsForRecreation() {
        val prompt = OnlineConversationErrorPrompts.fromCode(
            code = 2_002_400,
            message = "invalid request",
        )

        assertEquals("http_client_2002400", prompt?.id)
        assertEquals("服务请求失败", prompt?.title)
        assertEquals("重新创建", prompt?.restartText)
    }

    @Test
    fun fromCode_httpServerError_promptsForRecreation() {
        val prompt = OnlineConversationErrorPrompts.fromCode(
            code = 2_002_500,
            message = "internal error",
        )

        assertEquals("http_server_2002500", prompt?.id)
        assertEquals("服务请求失败", prompt?.title)
        assertEquals("重新创建", prompt?.restartText)
    }

    @Test
    fun fromCode_httpUpperBound_promptsForRecreation() {
        val prompt = OnlineConversationErrorPrompts.fromCode(
            code = 2_002_599,
            message = "gateway timeout",
        )

        assertEquals("http_server_2002599", prompt?.id)
        assertEquals("重新创建", prompt?.restartText)
    }

    @Test
    fun fromCode_httpAdjacentCode_returnsNoPrompt() {
        val prompt = OnlineConversationErrorPrompts.fromCode(
            code = 2_002_600,
            message = "outside http range",
        )

        assertEquals(null, prompt)
    }

    @Test
    fun fromCode_backendBusinessError_promptsForRetry() {
        val prompt = OnlineConversationErrorPrompts.fromCode(
            code = 2_005_001,
            message = "room unavailable",
        )

        assertEquals("biz_2005001", prompt?.id)
        assertEquals("服务端拒绝请求", prompt?.title)
        assertEquals("重新创建", prompt?.restartText)
    }

    @Test
    fun fromCode_backendBusinessUpperBound_promptsForRetry() {
        val prompt = OnlineConversationErrorPrompts.fromCode(
            code = 2_007_999,
            message = "service busy",
        )

        assertEquals("biz_2007999", prompt?.id)
        assertEquals("重新创建", prompt?.restartText)
    }

    @Test
    fun fromCode_backendBusinessErrorInOfflineMode_promptsForOfflineReinitialization() {
        val prompt = OnlineConversationErrorPrompts.fromCode(
            code = 2_005_001,
            message = "room unavailable",
            mode = OnlineConversationErrorPrompts.RuntimeMode.OFFLINE,
        )

        assertEquals("biz_2005001", prompt?.id)
        assertEquals("重新初始化", prompt?.restartText)
    }
}
