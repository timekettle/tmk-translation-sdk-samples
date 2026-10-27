package co.timekettle.translation.sample

import co.timekettle.translation.*

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.location.Address
import android.location.Geocoder
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.Build
import android.os.Bundle
import android.os.CancellationSignal
import android.os.Handler
import android.os.Looper
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Scaffold
import androidx.compose.ui.Modifier
import androidx.core.content.ContextCompat
import cafe.adriel.voyager.navigator.Navigator
import cafe.adriel.voyager.transitions.SlideTransition
import co.timekettle.translation.sample.ui.theme.TmkTranslationSDKTheme
import dagger.hilt.android.AndroidEntryPoint
import java.util.Locale
import java.util.TimeZone

@AndroidEntryPoint
class MainActivity : ComponentActivity() {

    private val diagnosticHandler = Handler(Looper.getMainLooper())
    private var diagnosticCallback: ((Map<String, Any?>) -> Unit)? = null
    private var locationManager: LocationManager? = null
    private var locationListener: LocationListener? = null
    private var locationCancellation: CancellationSignal? = null
    private var diagnosticTimeout: Runnable? = null
    private var geocoding = false
    private var diagnosticRequestId = 0

    private val requestPermissionLauncher =
        registerForActivityResult(ActivityResultContracts.RequestPermission()) { _ -> }
    private val locationPermissionLauncher =
        registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {
            if (diagnosticCallback != null) {
                if (hasLocationPermission()) requestDeviceLocation() else finishDeviceEnvironment("permission_denied")
            }
        }

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
                    Navigator(HomeScreen()) { navigator ->
                        SlideTransition(
                            navigator = navigator,
                            modifier = Modifier.padding(innerPadding)
                        )
                    }
                }
            }
        }
    }

    fun readSauceDeviceEnvironment(callback: (Map<String, Any?>) -> Unit) {
        if (diagnosticCallback != null) {
            callback(deviceEnvironmentPayload("busy"))
            return
        }
        diagnosticRequestId += 1
        diagnosticCallback = callback
        if (!hasLocationPermission()) {
            locationPermissionLauncher.launch(
                arrayOf(Manifest.permission.ACCESS_COARSE_LOCATION, Manifest.permission.ACCESS_FINE_LOCATION)
            )
        } else {
            requestDeviceLocation()
        }
    }

    private fun hasLocationPermission(): Boolean =
        ContextCompat.checkSelfPermission(this, Manifest.permission.ACCESS_COARSE_LOCATION) ==
            PackageManager.PERMISSION_GRANTED ||
            ContextCompat.checkSelfPermission(this, Manifest.permission.ACCESS_FINE_LOCATION) ==
            PackageManager.PERMISSION_GRANTED

    private fun requestDeviceLocation() {
        if (!hasLocationPermission()) {
            finishDeviceEnvironment("permission_denied")
            return
        }
        val manager = getSystemService(Context.LOCATION_SERVICE) as LocationManager
        locationManager = manager
        try {
            val providers = if (ContextCompat.checkSelfPermission(this, Manifest.permission.ACCESS_FINE_LOCATION) ==
                PackageManager.PERMISSION_GRANTED
            ) listOf(LocationManager.GPS_PROVIDER, LocationManager.NETWORK_PROVIDER)
            else listOf(LocationManager.NETWORK_PROVIDER)
            val provider = providers.firstOrNull(manager::isProviderEnabled)
            if (provider == null) {
                finishDeviceEnvironment("services_disabled")
                return
            }
            scheduleDiagnosticTimeout(20_000) { finishDeviceEnvironment("timeout") }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                val cancellation = CancellationSignal()
                locationCancellation = cancellation
                manager.getCurrentLocation(provider, cancellation, mainExecutor) { location ->
                    if (location == null) finishDeviceEnvironment("no_location") else geocodeDeviceLocation(location)
                }
            } else {
                val listener = LocationListener { location -> geocodeDeviceLocation(location) }
                locationListener = listener
                @Suppress("DEPRECATION")
                manager.requestSingleUpdate(provider, listener, Looper.getMainLooper())
            }
        } catch (error: SecurityException) {
            finishDeviceEnvironment("permission_denied", detail = error.message)
        } catch (error: Exception) {
            finishDeviceEnvironment("location_error", detail = error.message)
        }
    }

    private fun geocodeDeviceLocation(location: Location) {
        if (diagnosticCallback == null || geocoding) return
        if (location.latitude == 0.0 && location.longitude == 0.0) {
            finishDeviceEnvironment("invalid_location")
            return
        }
        geocoding = true
        locationCancellation = null
        locationListener?.let { locationManager?.removeUpdates(it) }
        locationListener = null
        scheduleDiagnosticTimeout(12_000) {
            finishDeviceEnvironment("ok", location, geocodeStatus = "timeout")
        }
        if (!Geocoder.isPresent()) {
            finishDeviceEnvironment("ok", location, geocodeStatus = "unavailable")
            return
        }
        val requestId = diagnosticRequestId
        Thread {
            var address: Address? = null
            var geocodeStatus = "no_result"
            var geocodeDetail: String? = null
            try {
                @Suppress("DEPRECATION")
                address = Geocoder(this, Locale.getDefault())
                    .getFromLocation(location.latitude, location.longitude, 1)
                    ?.firstOrNull()
                if (address != null) geocodeStatus = "ok"
            } catch (error: Exception) {
                geocodeStatus = "error"
                geocodeDetail = error.message
            }
            diagnosticHandler.post {
                if (diagnosticCallback != null && requestId == diagnosticRequestId) {
                    finishDeviceEnvironment("ok", location, address, geocodeStatus, geocodeDetail)
                }
            }
        }.apply { isDaemon = true }.start()
    }

    private fun scheduleDiagnosticTimeout(delayMs: Long, action: () -> Unit) {
        diagnosticTimeout?.let(diagnosticHandler::removeCallbacks)
        diagnosticTimeout = Runnable(action).also { diagnosticHandler.postDelayed(it, delayMs) }
    }

    private fun deviceEnvironmentPayload(
        status: String,
        location: Location? = null,
        address: Address? = null,
        geocodeStatus: String? = null,
        detail: String? = null,
    ): Map<String, Any?> = linkedMapOf<String, Any?>(
        "status" to status,
        "locale" to Locale.getDefault().toString(),
        "timeZone" to TimeZone.getDefault().id,
        "sample_network_environment" to DemoSettingsStore.loadNetworkEnvironment(this).name.lowercase(Locale.US),
    ).apply {
        if (location != null) {
            put("gps", linkedMapOf(
                "latitude" to location.latitude,
                "longitude" to location.longitude,
                "altitude" to (if (location.hasAltitude()) location.altitude else null),
                "horizontal_accuracy_m" to (if (location.hasAccuracy()) location.accuracy.toDouble() else null),
            ))
        }
        if (geocodeStatus != null) put("geocode_status", geocodeStatus)
        if (detail != null) put(if (status == "ok") "geocode_detail" else "detail", detail)
        if (address != null) put("address", mapOf(
            "country" to address.countryName,
            "country_code" to address.countryCode,
            "state_province" to address.adminArea,
            "county" to address.subAdminArea,
            "city" to address.locality,
            "district" to address.subLocality,
            "street" to address.thoroughfare,
            "street_number" to address.subThoroughfare,
            "postal_code" to address.postalCode,
        ))
    }

    private fun finishDeviceEnvironment(
        status: String,
        location: Location? = null,
        address: Address? = null,
        geocodeStatus: String? = null,
        detail: String? = null,
    ) {
        val callback = diagnosticCallback ?: return
        diagnosticCallback = null
        diagnosticTimeout?.let(diagnosticHandler::removeCallbacks)
        diagnosticTimeout = null
        locationCancellation?.cancel()
        locationCancellation = null
        locationListener?.let { locationManager?.removeUpdates(it) }
        locationListener = null
        locationManager = null
        geocoding = false
        callback(deviceEnvironmentPayload(status, location, address, geocodeStatus, detail))
    }

    override fun onDestroy() {
        diagnosticCallback = null
        diagnosticTimeout?.let(diagnosticHandler::removeCallbacks)
        locationCancellation?.cancel()
        locationListener?.let { locationManager?.removeUpdates(it) }
        super.onDestroy()
    }
}
