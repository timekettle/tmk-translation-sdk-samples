package co.timekettle.translation.sample

import co.timekettle.translation.enums.TmkTranslateDeliveryMode
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * [TranslateModeOption] —— 离线 Demo 翻译模式选择弹窗的展示映射单测。
 *
 * 重点:DEFAULT 归一到 STABLE 展示(离线 D1:仅 PARTIAL 产中间态,DEFAULT 语义等同 STABLE),
 * 且每个选项承载的 mode 与在线枚举一一对应。
 */
class TranslateModeOptionTest {

    @Test
    fun `from maps DEFAULT to STABLE display`() {
        assertEquals(TranslateModeOption.STABLE, TranslateModeOption.from(TmkTranslateDeliveryMode.DEFAULT))
    }

    @Test
    fun `from maps STABLE to STABLE`() {
        assertEquals(TranslateModeOption.STABLE, TranslateModeOption.from(TmkTranslateDeliveryMode.STABLE))
    }

    @Test
    fun `from maps PARTIAL to PARTIAL`() {
        assertEquals(TranslateModeOption.PARTIAL, TranslateModeOption.from(TmkTranslateDeliveryMode.PARTIAL))
    }

    @Test
    fun `each option carries the matching delivery mode`() {
        assertEquals(TmkTranslateDeliveryMode.PARTIAL, TranslateModeOption.PARTIAL.mode)
        assertEquals(TmkTranslateDeliveryMode.STABLE, TranslateModeOption.STABLE.mode)
    }
}
