package co.timekettle.translation.sample

import co.timekettle.translation.*

import android.Manifest
import android.content.pm.PackageManager
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.runtime.Composable
import cafe.adriel.voyager.core.screen.Screen
import cafe.adriel.voyager.core.annotation.ExperimentalVoyagerApi
import cafe.adriel.voyager.navigator.NavigatorDisposeBehavior
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Scaffold
import androidx.compose.ui.Modifier
import androidx.core.content.ContextCompat
import cafe.adriel.voyager.navigator.Navigator
import cafe.adriel.voyager.transitions.SlideTransition
import co.timekettle.translation.sample.ui.theme.TmkTranslationSDKTheme
import dagger.hilt.android.AndroidEntryPoint

@AndroidEntryPoint
class MainActivity : ComponentActivity() {

    private val requestPermissionLauncher =
        registerForActivityResult(ActivityResultContracts.RequestPermission()) { _ -> }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()

        if (ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO)
            != PackageManager.PERMISSION_GRANTED
        ) {
            requestPermissionLauncher.launch(Manifest.permission.RECORD_AUDIO)
        }

        setContent {
            TmkTranslationSDKTheme {
                Scaffold(modifier = Modifier.fillMaxSize()) { innerPadding ->
                    DemoNavigation(modifier = Modifier.padding(innerPadding))
                }
            }
        }
    }
}

/** Demo 统一导航宿主，页面状态与退场动画共用同一生命周期。 */
@OptIn(ExperimentalVoyagerApi::class)
@Composable
internal fun DemoNavigation(initialScreen: Screen = HomeScreen(), modifier: Modifier = Modifier) {
    // pop后页面仍在退场动画中；由Transition统一在动画结束后释放，避免VM被重建并再次sdkInit。
    Navigator(initialScreen, disposeBehavior = NavigatorDisposeBehavior(disposeSteps = false)) { navigator ->
        SlideTransition(navigator = navigator, modifier = modifier, disposeScreenAfterTransitionEnd = true)
    }
}
