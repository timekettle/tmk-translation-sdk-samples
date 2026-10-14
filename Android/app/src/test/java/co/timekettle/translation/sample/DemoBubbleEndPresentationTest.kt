package co.timekettle.translation.sample

import android.app.Application
import android.os.Looper
import androidx.compose.ui.graphics.Color
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelStore
import co.timekettle.translation.listener.TmkTranslationListener
import co.timekettle.translation.model.BubbleRowData
import co.timekettle.translation.model.Result
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.annotation.LooperMode

/** 在线结束原因不参与边框；离线诊断四色与缺失原因兜底保持原行为。 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [30])
@LooperMode(LooperMode.Mode.PAUSED)
class DemoBubbleEndPresentationTest {
    @Test
    fun onlineListenIgnoresReasonAndKeepsLeftBorder() = withViewModel(online = true, oneToOne = false) { vm ->
        val row = endBubble(vm, DemoConversationLane.LEFT, "online_bubble_end", "length")
        assertNull(row.bubbleEndReason)
        assertEquals(Color(0xFF34C759), demoBubbleEndBorderColor(row.bubbleEndReason, false))
    }

    @Test
    fun onlineOneToOneIgnoresReasonAndKeepsBothLaneBorders() = withViewModel(online = true, oneToOne = true) { vm ->
        for (lane in DemoConversationLane.entries) {
            val row = endBubble(vm, lane, "online_bubble_end", "error")
            assertNull(row.bubbleEndReason)
            assertEquals(if (lane == DemoConversationLane.RIGHT) Color(0xFF007AFF) else Color(0xFF34C759),
                demoBubbleEndBorderColor(row.bubbleEndReason, lane == DemoConversationLane.RIGHT))
        }
    }

    @Test
    fun nullReasonUsesOriginalOnlineLaneBorders() {
        assertEquals(Color(0xFF34C759), demoBubbleEndBorderColor(null, false))
        assertEquals(Color(0xFF007AFF), demoBubbleEndBorderColor(null, true))
    }

    @Test
    fun offlineListenRetainsReasonAndMissingReasonFallback() = checkOffline(oneToOne = false)

    @Test
    fun offlineOneToOneRetainsReasonAndMissingReasonFallback() = checkOffline(oneToOne = true)

    @Test
    fun offlineDiagnosticBorderColorsRemainUnchanged() {
        for (isRight in listOf(false, true)) {
            assertEquals(Color(0xFFFFCC00), demoBubbleEndBorderColor("length", isRight))
            assertEquals(Color(0xFFFF3B30), demoBubbleEndBorderColor("error", isRight))
            for (reason in listOf("natural", "native_final", "empty_final")) {
                assertEquals(if (isRight) Color(0xFF007AFF) else Color(0xFF34C759),
                    demoBubbleEndBorderColor(reason, isRight))
            }
            for (reason in listOf("other", "stop", "release", "unknown", "")) {
                assertEquals(Color(0xFFAF52DE), demoBubbleEndBorderColor(reason, isRight))
            }
        }
    }

    private fun checkOffline(oneToOne: Boolean) = withViewModel(online = false, oneToOne = oneToOne) { vm ->
        val lanes = if (oneToOne) DemoConversationLane.entries else listOf(DemoConversationLane.LEFT)
        for (lane in lanes) {
            for (reason in listOf(null, "", " \t ", "length", "error", "natural", "native_final", "empty_final", "other", "unknown")) {
                val row = endBubble(vm, lane, "offline_bubble_end", reason)
                assertEquals(reason?.trim()?.takeIf { it.isNotEmpty() } ?: "other", row.bubbleEndReason)
                if (reason.isNullOrBlank()) {
                    assertEquals(Color(0xFFAF52DE), demoBubbleEndBorderColor(row.bubbleEndReason, lane == DemoConversationLane.RIGHT))
                }
            }
        }
    }

    private fun endBubble(vm: ViewModel, lane: DemoConversationLane, eventName: String, reason: String?): BubbleRowData {
        val assembler = vm.javaClass.getDeclaredField("bubbleAssembler").apply { isAccessible = true }
            .get(vm) as DemoConversationBubbleAssembler
        val bubbleId = "bubble-${lane.rawValue}-${reason?.hashCode() ?: "missing"}"
        assembler.consume(DemoConversationEvent(bubbleId = bubbleId, sessionId = "1", lane = lane,
            stage = DemoConversationStage.ASR, isFinal = true, text = "source",
            sourceLangCode = "zh-CN", targetLangCode = "en-US"))
        val extra = mutableMapOf<String, Any?>("channel" to lane.rawValue)
        if (reason != null) extra["end_reason"] = reason
        val result = Result.Builder<String>().setSessionId("1").setBubbleId(bubbleId)
            .setData("bubble_end").setSrcCode("zh-CN").setDstCode("en-US")
            .setIsLast(true).setExtraData(extra).build()
        val listenerField = if (vm is OnlineListenViewModel) "listener" else "translationListener"
        val listener = vm.javaClass.getDeclaredField(listenerField).apply { isAccessible = true }
            .get(vm) as TmkTranslationListener
        listener.onEvent(eventName, result)
        return assembler.snapshot().single { it.bubbleId == bubbleId }.also { assertTrue(it.isBubbleEnded) }
    }

    private fun withViewModel(online: Boolean, oneToOne: Boolean, block: (ViewModel) -> Unit) {
        val application: Application = RuntimeEnvironment.getApplication()
        val vm = when {
            online && oneToOne -> Online1v1ViewModel(application)
            online -> OnlineListenViewModel(application)
            oneToOne -> Offline1v1ViewModel(application)
            else -> OfflineListenViewModel(application)
        }
        val store = ViewModelStore()
        store.put("bubble", vm)
        try {
            block(vm)
        } finally {
            store.clear()
            shadowOf(Looper.getMainLooper()).idle()
        }
    }
}
