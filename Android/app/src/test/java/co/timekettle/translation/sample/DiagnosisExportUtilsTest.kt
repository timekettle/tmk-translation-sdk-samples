package co.timekettle.translation.sample

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.util.zip.ZipFile

class DiagnosisExportUtilsTest {

    @Test
    fun zipDirectory_includesNestedRegularFilesWithRelativePaths() {
        val root = createTempDir(prefix = "diagnosis-root")
        val source = File(root, "sdk_diagnosis").apply { mkdirs() }
        File(source, "sdk.log").writeText("sdk")
        File(source, "workflow").mkdirs()
        File(source, "workflow/workflow.log").writeText("workflow")
        val output = File(root, "diagnosis.zip")

        DiagnosisExportUtils.zipDirectory(source, output)

        assertTrue(output.exists())
        ZipFile(output).use { zip ->
            val names = zip.entries().asSequence().map { it.name }.toList().sorted()
            assertEquals(listOf("sdk.log", "workflow/workflow.log"), names)
        }
    }
}
