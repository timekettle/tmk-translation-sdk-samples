package co.timekettle.translation.sample

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import co.timekettle.translation.config.TmkTranslationNetworkEnvironment
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.util.zip.ZipFile

@RunWith(AndroidJUnit4::class)
class DemoSettingsInstrumentedTest {

    @Test
    fun sensitiveWordRedactionDefaultsToTrueAndRoundTrips() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        context.getSharedPreferences("demo_settings", android.content.Context.MODE_PRIVATE)
            .edit()
            .clear()
            .commit()

        assertTrue(DemoSettingsStore.loadSensitiveWordRedactionEnabled(context))

        DemoSettingsStore.saveSensitiveWordRedactionEnabled(context, false)

        assertFalse(DemoSettingsStore.loadSensitiveWordRedactionEnabled(context))

        DemoSettingsStore.saveSensitiveWordRedactionEnabled(context, true)

        assertTrue(DemoSettingsStore.loadSensitiveWordRedactionEnabled(context))
    }

    @Test
    fun networkEnvironmentPersistsInDeviceSharedPreferences() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext

        DemoSettingsStore.saveNetworkEnvironment(context, TmkTranslationNetworkEnvironment.PRE)

        assertEquals(TmkTranslationNetworkEnvironment.PRE, DemoSettingsStore.loadNetworkEnvironment(context))
    }

    @Test
    fun diagnosisZipCanBeCreatedOnDeviceCacheDirectory() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val root = File(context.cacheDir, "diagnosis-export-test").apply {
            deleteRecursively()
            mkdirs()
        }
        File(root, "sdk.log").writeText("sdk")
        File(root, "workflow").mkdirs()
        File(root, "workflow/workflow.log").writeText("workflow")
        val output = File(context.cacheDir, "diagnosis-export-test.zip").apply { delete() }

        DiagnosisExportUtils.zipDirectory(root, output)

        assertTrue(output.exists())
        ZipFile(output).use { zip ->
            val names = zip.entries().asSequence().map { it.name }.toList().sorted()
            assertEquals(listOf("sdk.log", "workflow/workflow.log"), names)
        }
    }
}
