package co.timekettle.translation.sample

import org.junit.Assert.assertEquals
import org.junit.Test

class SettingsVersionLabelTest {
    @Test
    fun sdkVersionLabel_usesSdkReportedVersion() {
        assertEquals(
            "TmkTranslationSDK v1.2.0-runtime",
            settingsSdkVersionLabel("1.2.0-runtime")
        )
    }
}
