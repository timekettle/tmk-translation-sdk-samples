package co.timekettle.translation.sample

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class DemoSettingsInstrumentedTest {

    @Test
    fun diagnosisEnabledDefaultsOffAndPersistsInDeviceSharedPreferences() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        context.getSharedPreferences("demo_settings", 0)
            .edit()
            .remove("diagnosis_enabled")
            .commit()

        assertFalse(DemoSettingsStore.loadDiagnosisEnabled(context))

        DemoSettingsStore.saveDiagnosisEnabled(context, true)
        assertTrue(DemoSettingsStore.loadDiagnosisEnabled(context))

        DemoSettingsStore.saveDiagnosisEnabled(context, false)
        assertFalse(DemoSettingsStore.loadDiagnosisEnabled(context))
    }
}
