package co.timekettle.translation.sample

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

class OnlineScreenViewModelScopeTest {

    @Test
    fun onlineScreensUseVoyagerScopedHiltViewModels() {
        val screens = listOf(
            "TranslationScreen.kt" to "OnlineListenViewModel",
            "DualChannelScreen.kt" to "Online1v1ViewModel",
        )

        screens.forEach { (fileName, viewModelName) ->
            val source = File("src/main/java/co/timekettle/translation/$fileName").readText()

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
}
