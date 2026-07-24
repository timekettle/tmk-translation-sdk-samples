package co.timekettle.translation.sample

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class OnlineConversationErrorPromptsTest {

    @Test
    fun `invalid language prompt follows online contract`() {
        val prompt = OnlineConversationErrorPrompts.fromCode(
            code = TmkTranslationException.ErrorCodes.INVALID_LANGUAGE_CODE,
            message = "Unsupported language",
            mode = OnlineConversationErrorPrompts.RuntimeMode.ONLINE,
        )

        requireNotNull(prompt)
        assertEquals("语言不支持", prompt.title)
        assertEquals("重新选择", prompt.restartText)
        assertTrue(prompt.message.contains("重新创建对话"))
    }

    @Test
    fun `invalid language prompt follows offline contract`() {
        val prompt = OnlineConversationErrorPrompts.fromCode(
            code = TmkTranslationException.ErrorCodes.INVALID_LANGUAGE_CODE,
            message = "Unsupported language",
            mode = OnlineConversationErrorPrompts.RuntimeMode.OFFLINE,
        )

        requireNotNull(prompt)
        assertEquals("语言不支持", prompt.title)
        assertEquals("重新选择", prompt.restartText)
        assertTrue(prompt.message.contains("重新初始化离线通道"))
    }
}
