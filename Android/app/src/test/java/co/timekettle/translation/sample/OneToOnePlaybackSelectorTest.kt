package co.timekettle.translation.sample

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * [OneToOnePlaybackSelector] 单测:
 * 立体声按播放音源拆一路(输出单声道)、非立体声直接播、低延迟单路帧仅播选中音源。
 */
class OneToOnePlaybackSelectorTest {

    // 2 个立体声帧(16LE, 布局 L L R R):left 样本 = 0x11 0x22 / 0x33 0x44,right 样本 = 0xAA 0xBB / 0xCC 0xDD。
    private val stereo = byteArrayOf(
        0x11, 0x22, 0xAA.toByte(), 0xBB.toByte(),
        0x33, 0x44, 0xCC.toByte(), 0xDD.toByte(),
    )
    private val expectLeft = byteArrayOf(0x11, 0x22, 0x33, 0x44)
    private val expectRight = byteArrayOf(0xAA.toByte(), 0xBB.toByte(), 0xCC.toByte(), 0xDD.toByte())
    private val mono = byteArrayOf(1, 2, 3, 4)

    @Test
    fun audioRouteFrom_parsesLowercaseAndTrims() {
        assertEquals(OneToOnePlaybackSelector.AudioRoute.LEFT, OneToOnePlaybackSelector.AudioRoute.from("left"))
        assertEquals(OneToOnePlaybackSelector.AudioRoute.RIGHT, OneToOnePlaybackSelector.AudioRoute.from(" RIGHT "))
        assertEquals(OneToOnePlaybackSelector.AudioRoute.STEREO, OneToOnePlaybackSelector.AudioRoute.from("stereo"))
        assertNull(OneToOnePlaybackSelector.AudioRoute.from(null))
        assertNull(OneToOnePlaybackSelector.AudioRoute.from(""))
        assertNull(OneToOnePlaybackSelector.AudioRoute.from("center"))
    }

    // ---- 立体声(route=null,标准模式混合流):按播放音源拆一路,输出单声道 ----

    @Test
    fun stereoNoRoute_splitsByPlaybackModeToMono() {
        val left = OneToOnePlaybackSelector.selectPlaybackData(
            stereo, 2, OneToOnePlaybackMode.LEFT, null,
        )!!
        assertArrayEquals(expectLeft, left.data)
        assertEquals(1, left.channelCount)

        val right = OneToOnePlaybackSelector.selectPlaybackData(
            stereo, 2, OneToOnePlaybackMode.RIGHT, null,
        )!!
        assertArrayEquals(expectRight, right.data)
        assertEquals(1, right.channelCount)
    }

    // ---- 立体声(route=stereo):同样按播放音源拆一路 ----

    @Test
    fun stereoRoute_splitsByPlaybackModeToMono() {
        val left = OneToOnePlaybackSelector.selectPlaybackData(
            stereo, 2, OneToOnePlaybackMode.LEFT, OneToOnePlaybackSelector.AudioRoute.STEREO,
        )!!
        assertArrayEquals(expectLeft, left.data)
        assertEquals(1, left.channelCount)
    }

    @Test
    fun stereoSingleActiveRight_playsRightWhenSelectedLeftIsSilent() {
        val out = OneToOnePlaybackSelector.selectPlaybackData(
            data = stereo,
            channelCount = 2,
            playbackMode = OneToOnePlaybackMode.LEFT,
            audioRoute = OneToOnePlaybackSelector.AudioRoute.STEREO,
            leftActive = false,
            rightActive = true,
        )!!

        assertArrayEquals(expectRight, out.data)
        assertEquals(1, out.channelCount)
    }

    @Test
    fun stereoSingleActiveLeft_playsLeftWhenSelectedRightIsSilent() {
        val out = OneToOnePlaybackSelector.selectPlaybackData(
            data = stereo,
            channelCount = 2,
            playbackMode = OneToOnePlaybackMode.RIGHT,
            audioRoute = OneToOnePlaybackSelector.AudioRoute.STEREO,
            leftActive = true,
            rightActive = false,
        )!!

        assertArrayEquals(expectLeft, out.data)
        assertEquals(1, out.channelCount)
    }

    // ---- 非立体声:直接播放,声道数不变 ----

    @Test
    fun mono_playsDirectly() {
        val out = OneToOnePlaybackSelector.selectPlaybackData(
            mono, 1, OneToOnePlaybackMode.LEFT, null,
        )!!
        assertArrayEquals(mono, out.data)
        assertEquals(1, out.channelCount)
    }

    // ---- 低延迟单路帧(route=left/right):仅播选中音源那一路,对侧丢弃 ----

    @Test
    fun routeLeft_playsWhenModeLeft_dropsWhenModeRight() {
        val out = OneToOnePlaybackSelector.selectPlaybackData(
            mono, 1, OneToOnePlaybackMode.LEFT, OneToOnePlaybackSelector.AudioRoute.LEFT,
        )!!
        assertArrayEquals(mono, out.data)
        assertEquals(1, out.channelCount)
        assertNull(
            OneToOnePlaybackSelector.selectPlaybackData(
                mono, 1, OneToOnePlaybackMode.RIGHT, OneToOnePlaybackSelector.AudioRoute.LEFT,
            ),
        )
    }

    @Test
    fun routeRight_playsWhenModeRight_dropsWhenModeLeft() {
        val out = OneToOnePlaybackSelector.selectPlaybackData(
            mono, 1, OneToOnePlaybackMode.RIGHT, OneToOnePlaybackSelector.AudioRoute.RIGHT,
        )!!
        assertArrayEquals(mono, out.data)
        assertNull(
            OneToOnePlaybackSelector.selectPlaybackData(
                mono, 1, OneToOnePlaybackMode.LEFT, OneToOnePlaybackSelector.AudioRoute.RIGHT,
            ),
        )
    }

    @Test
    fun routeLeftRight_neverSplits_passesWholeFrameAndChannelCount() {
        // 低延迟单路帧(route=left/right)本身即单声道,绝不按 stereo 拆分:
        // 即便传入可拆的数据 + channelCount=2,也应整帧返回并透传原 channelCount。
        val out = OneToOnePlaybackSelector.selectPlaybackData(
            stereo, 2, OneToOnePlaybackMode.LEFT, OneToOnePlaybackSelector.AudioRoute.LEFT,
        )!!
        assertArrayEquals(stereo, out.data) // 未拆分,整帧
        assertEquals(2, out.channelCount)   // 透传原声道数
    }

    @Test
    fun nonStereoNoRoute_playsDirectlyKeepingChannelCount() {
        // 非立体声(channelCount<2 无法拆)且无 route:原样直接播,声道数保持。
        val out = OneToOnePlaybackSelector.selectPlaybackData(
            mono, 1, OneToOnePlaybackMode.RIGHT, null,
        )!!
        assertArrayEquals(mono, out.data)
        assertEquals(1, out.channelCount)
    }

    @Test
    fun emptyData_returnsNull() {
        assertNull(
            OneToOnePlaybackSelector.selectPlaybackData(
                ByteArray(0), 2, OneToOnePlaybackMode.LEFT, OneToOnePlaybackSelector.AudioRoute.STEREO,
            ),
        )
    }

    @Test
    fun defaultPlaybackMode_isLeft() {
        assertEquals(OneToOnePlaybackMode.LEFT, OneToOnePlaybackMode.entries.first())
    }
}
