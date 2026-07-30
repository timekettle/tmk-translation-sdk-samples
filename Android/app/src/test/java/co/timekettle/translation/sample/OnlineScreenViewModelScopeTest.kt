package co.timekettle.translation.sample

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

class OnlineScreenViewModelScopeTest {

    @get:Rule
    val temporaryFolder = TemporaryFolder()

    @Test
    fun sourceResolverSupportsCommonGradleWorkingDirectories() {
        val repositoryRoot = temporaryFolder.newFolder("repository")
        val sourceFile = File(
            repositoryRoot,
            "Android/app/src/main/java/co/timekettle/translation/sample/TranslationScreen.kt",
        ).apply {
            requireNotNull(parentFile).mkdirs()
            writeText("// source")
        }

        listOf(
            repositoryRoot,
            File(repositoryRoot, "Android"),
            File(repositoryRoot, "Android/app"),
        ).forEach { workingDirectory ->
            assertEquals(sourceFile, resolveDemoSourceFile("TranslationScreen.kt", workingDirectory))
        }
    }

    @Test
    fun onlineScreensUseVoyagerScopedHiltViewModels() {
        val screens = listOf(
            "TranslationScreen.kt" to "OnlineListenViewModel",
            "DualChannelScreen.kt" to "Online1v1ViewModel",
        )

        screens.forEach { (fileName, viewModelName) ->
            val source = resolveDemoSourceFile(fileName).readText()

            assertTrue(
                "$fileName must use Voyager's Hilt ViewModel integration",
                source.contains("import cafe.adriel.voyager.hilt.getViewModel"),
            )
            assertTrue(
                "$fileName must bind $viewModelName to the Voyager Screen lifecycle",
                source.contains("val viewModel: $viewModelName = getViewModel()"),
            )
            assertFalse(
                "$fileName must not use Navigation Compose hiltViewModel inside a Voyager Screen",
                source.contains("androidx.hilt.navigation.compose.hiltViewModel"),
            )
        }
    }

    private fun resolveDemoSourceFile(
        fileName: String,
        workingDirectory: File = File(requireNotNull(System.getProperty("user.dir"))),
    ): File {
        val sourcePath = "src/main/java/co/timekettle/translation/sample/$fileName"
        val candidates = listOf(
            File(workingDirectory, sourcePath),
            File(workingDirectory, "app/$sourcePath"),
            File(workingDirectory, "Android/app/$sourcePath"),
        )
        return candidates.firstOrNull(File::isFile)
            ?: throw AssertionError(
                "Unable to locate $fileName from user.dir=${workingDirectory.absolutePath}. " +
                    "Checked: ${candidates.joinToString { it.absolutePath }}",
            )
    }
}
