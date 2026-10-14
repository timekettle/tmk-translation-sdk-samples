package co.timekettle.translation.sample

import android.app.Application
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelStore
import co.timekettle.translation.config.TmkTranslationRoomConfig
import co.timekettle.translation.enums.Scenario
import co.timekettle.translation.enums.TranslationMode
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

/** 使用发布 SDK 的公开配置验证 Demo 设置，不依赖混淆后的 SDK 私有字段。 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [30])
class OfflineBubbleSettingsTest {
    @Test fun listenStartsWithDefaultSettings() = checkDefaults(false)
    @Test fun oneToOneStartsWithDefaultSettings() = checkDefaults(true)
    @Test fun listenSavesSettingsBeforeChannelCreation() = checkUpdates(false)
    @Test fun oneToOneSavesSettingsBeforeChannelCreation() = checkUpdates(true)
    @Test fun listenClampsDemoSliderBounds() = checkBounds(false)
    @Test fun oneToOneClampsDemoSliderBounds() = checkBounds(true)

    private fun checkDefaults(oneToOne: Boolean) = withViewModel(oneToOne) { vm ->
        assertEquals(false, enabled(vm))
        assertEquals(60, threshold(vm))
    }

    private fun checkUpdates(oneToOne: Boolean) = withViewModel(oneToOne) { vm ->
        setEnabled(vm, true)
        setThreshold(vm, 125)
        // 与 Demo 建房入口一致，将设置传给实际发布 SDK 的 Builder。
        val roomConfig = TmkTranslationRoomConfig.Builder()
            .setMode(TranslationMode.OFFLINE)
            .setChannelScenario(if (oneToOne) Scenario.ONE_TO_ONE else Scenario.LISTEN)
            .setSourceLang("zh-CN").setTargetLang("en-US")
            .setOfflineBubbleLengthSplitEnabled(enabled(vm))
            .setOfflineBubbleLengthSplitThreshold(threshold(vm)).build()
        assertEquals(true, roomConfig.offlineBubbleLengthSplitEnabled)
        assertEquals(125, roomConfig.offlineBubbleLengthSplitThreshold)
        setEnabled(vm, false)
        assertEquals(false, enabled(vm))
    }

    private fun checkBounds(oneToOne: Boolean) = withViewModel(oneToOne) { vm ->
        for ((input, expected) in listOf(-1 to 10, 10 to 10, 60 to 60, 500 to 500, 501 to 500)) {
            setThreshold(vm, input)
            assertEquals(expected, threshold(vm))
        }
    }

    private fun enabled(vm: ViewModel): Boolean = when (vm) {
        is OfflineListenViewModel -> vm.offlineBubbleLengthSplitEnabled.value
        is Offline1v1ViewModel -> vm.offlineBubbleLengthSplitEnabled.value
        else -> error("Unknown offline Demo")
    }
    private fun threshold(vm: ViewModel): Int = when (vm) {
        is OfflineListenViewModel -> vm.offlineBubbleLengthSplitThreshold.value
        is Offline1v1ViewModel -> vm.offlineBubbleLengthSplitThreshold.value
        else -> error("Unknown offline Demo")
    }
    private fun setThreshold(vm: ViewModel, value: Int) = when (vm) {
        is OfflineListenViewModel -> vm.setOfflineBubbleLengthSplitThreshold(value)
        is Offline1v1ViewModel -> vm.setOfflineBubbleLengthSplitThreshold(value)
        else -> error("Unknown offline Demo")
    }
    private fun setEnabled(vm: ViewModel, value: Boolean) = when (vm) {
        is OfflineListenViewModel -> vm.setOfflineBubbleLengthSplitEnabled(value)
        is Offline1v1ViewModel -> vm.setOfflineBubbleLengthSplitEnabled(value)
        else -> error("Unknown offline Demo")
    }
    private fun withViewModel(oneToOne: Boolean, block: (ViewModel) -> Unit) {
        val app: Application = RuntimeEnvironment.getApplication()
        val vm = if (oneToOne) Offline1v1ViewModel(app) else OfflineListenViewModel(app)
        val store = ViewModelStore()
        store.put("offline", vm)
        try { block(vm) } finally { store.clear() }
    }
}
