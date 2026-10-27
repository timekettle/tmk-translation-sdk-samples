package co.timekettle.saas.sample

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.location.Address
import android.location.Geocoder
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.Build
import android.os.CancellationSignal
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.Locale
import java.util.TimeZone

class MainActivity : FlutterActivity() {
    private val handler = Handler(Looper.getMainLooper())
    private var diagnosticResult: MethodChannel.Result? = null
    private var locationManager: LocationManager? = null
    private val locationListeners = mutableListOf<LocationListener>()
    private val locationCancellations = mutableListOf<CancellationSignal>()
    private var timeout: Runnable? = null
    private var geocoding = false
    private var bestLocation: Location? = null
    private var bestLocationSource: String? = null
    private var activeProviders: List<String> = emptyList()
    private var precisePermission = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "tmk.sauce.deviceEnvironment")
            .setMethodCallHandler { call, result ->
                if (call.method == "read") readDeviceEnvironment(result)
                else result.notImplemented()
            }
    }

    override fun onStart() {
        super.onStart()
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO)
            != PackageManager.PERMISSION_GRANTED
        ) {
            ActivityCompat.requestPermissions(
                this,
                arrayOf(Manifest.permission.RECORD_AUDIO),
                1001,
            )
        }
    }

    private fun readDeviceEnvironment(result: MethodChannel.Result) {
        if (diagnosticResult != null) {
            result.error("busy", "Location request already running", null)
            return
        }
        diagnosticResult = result
        precisePermission = hasFineLocationPermission()
        activeProviders = emptyList()
        if (!hasFineLocationPermission()) {
            ActivityCompat.requestPermissions(
                this,
                arrayOf(Manifest.permission.ACCESS_COARSE_LOCATION, Manifest.permission.ACCESS_FINE_LOCATION),
                1002,
            )
            return
        }
        requestLocation()
    }

    private fun hasLocationPermission(): Boolean =
        ContextCompat.checkSelfPermission(this, Manifest.permission.ACCESS_COARSE_LOCATION) ==
            PackageManager.PERMISSION_GRANTED ||
            hasFineLocationPermission()

    private fun hasFineLocationPermission(): Boolean =
        ContextCompat.checkSelfPermission(this, Manifest.permission.ACCESS_FINE_LOCATION) ==
            PackageManager.PERMISSION_GRANTED

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == 1002 && diagnosticResult != null) {
            if (hasLocationPermission()) requestLocation() else finish("permission_denied")
        }
    }

    private fun requestLocation() {
        if (!hasLocationPermission()) {
            finish("permission_denied")
            return
        }
        val manager = getSystemService(Context.LOCATION_SERVICE) as LocationManager
        locationManager = manager
        precisePermission = hasFineLocationPermission()
        val available = manager.getProviders(true).toSet()
        activeProviders = listOfNotNull(
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) LocationManager.FUSED_PROVIDER else null,
            LocationManager.NETWORK_PROVIDER,
            if (precisePermission) LocationManager.GPS_PROVIDER else null,
        ).filter { it in available }
        if (activeProviders.isEmpty()) {
            finish("services_disabled")
            return
        }
        bestLocation = null
        bestLocationSource = null
        // Sauce devices may hold a fresh simulated fix without emitting a new
        // GPS event. Use only a recent cache entry, then seek a better fix.
        for (provider in activeProviders + LocationManager.PASSIVE_PROVIDER) {
            try {
                val cached = manager.getLastKnownLocation(provider)
                if (cached != null && locationAgeMs(cached)?.let { it <= 120_000 } == true) {
                    acceptLocation(cached, "cached_$provider")
                }
            } catch (_: SecurityException) {
                // A coarse grant can exclude a precise provider on Android 12+.
            } catch (_: IllegalArgumentException) {
                // Some vendor images do not expose the passive provider.
            }
        }
        if (geocoding) return
        scheduleTimeout(20_000) {
            val fallback = bestLocation
            if (fallback != null) geocode(fallback, bestLocationSource ?: "cached")
            else finish("timeout", detail = "providers=${activeProviders.joinToString(",")}")
        }
        var registered = 0
        for (provider in activeProviders) {
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                    val signal = CancellationSignal()
                    locationCancellations.add(signal)
                    manager.getCurrentLocation(provider, signal, mainExecutor) { location ->
                        if (location != null) acceptLocation(location, "current_$provider")
                    }
                } else {
                    val listener = LocationListener { location ->
                        acceptLocation(location, "current_$provider")
                    }
                    locationListeners.add(listener)
                    @Suppress("DEPRECATION")
                    manager.requestSingleUpdate(provider, listener, Looper.getMainLooper())
                }
                registered++
            } catch (_: SecurityException) {
                // Continue with providers allowed by the granted precision.
            } catch (_: IllegalArgumentException) {
                // An advertised provider may disappear during the request.
            }
        }
        if (registered == 0 && bestLocation == null) finish("location_error", detail = "no_provider_registered")
    }

    private fun locationAgeMs(location: Location): Long? {
        val timestamp = location.elapsedRealtimeNanos
        if (timestamp <= 0) return null
        return ((SystemClock.elapsedRealtimeNanos() - timestamp) / 1_000_000).coerceAtLeast(0)
    }

    private fun acceptLocation(location: Location, source: String) {
        if (diagnosticResult == null || geocoding) return
        if (location.latitude !in -90.0..90.0 || location.longitude !in -180.0..180.0 ||
            (location.latitude == 0.0 && location.longitude == 0.0)
        ) return
        val previous = bestLocation
        if (previous == null ||
            (source.startsWith("current_") && bestLocationSource?.startsWith("cached_") == true) ||
            (location.hasAccuracy() && (!previous.hasAccuracy() || location.accuracy < previous.accuracy)) ||
            (location.hasAccuracy() == previous.hasAccuracy() &&
                location.accuracy == previous.accuracy &&
                (locationAgeMs(location) ?: Long.MAX_VALUE) < (locationAgeMs(previous) ?: Long.MAX_VALUE))
        ) {
            bestLocation = location
            bestLocationSource = source
        }
        if (source.startsWith("current_") && precisePermission &&
            location.hasAccuracy() && location.accuracy <= 100f
        ) {
            geocode(location, source)
        }
    }

    private fun geocode(location: Location, source: String) {
        if (diagnosticResult == null || geocoding) return
        if (location.latitude == 0.0 && location.longitude == 0.0) {
            finish("invalid_location")
            return
        }
        geocoding = true
        stopLocationRequests()
        scheduleTimeout(12_000) {
            finish("ok", location, geocodeStatus = "timeout", locationSource = source)
        }
        if (!Geocoder.isPresent()) {
            finish("ok", location, geocodeStatus = "unavailable", locationSource = source)
            return
        }
        Thread {
            var address: Address? = null
            var status = "no_result"
            var detail: String? = null
            try {
                @Suppress("DEPRECATION")
                val matches = Geocoder(this, Locale.getDefault()).getFromLocation(
                    location.latitude, location.longitude, 1,
                )
                address = matches?.firstOrNull()
                if (address != null) status = "ok"
            } catch (error: Exception) {
                status = "error"
                detail = error.message
            }
            handler.post {
                if (diagnosticResult != null) {
                    finish("ok", location, address, status, detail, source)
                }
            }
        }.apply { isDaemon = true }.start()
    }

    private fun scheduleTimeout(delayMs: Long, action: () -> Unit) {
        timeout?.let(handler::removeCallbacks)
        timeout = Runnable(action).also { handler.postDelayed(it, delayMs) }
    }

    private fun stopLocationRequests() {
        locationCancellations.forEach { it.cancel() }
        locationCancellations.clear()
        locationListeners.forEach { listener ->
            runCatching { locationManager?.removeUpdates(listener) }
        }
        locationListeners.clear()
    }

    private fun finish(
        status: String,
        location: Location? = null,
        address: Address? = null,
        geocodeStatus: String? = null,
        detail: String? = null,
        locationSource: String? = null,
    ) {
        val result = diagnosticResult ?: return
        diagnosticResult = null
        timeout?.let(handler::removeCallbacks)
        timeout = null
        stopLocationRequests()
        locationManager = null
        geocoding = false
        val payload = linkedMapOf<String, Any?>(
            "status" to status,
            "locale" to Locale.getDefault().toString(),
            "timeZone" to TimeZone.getDefault().id,
            "location_permission" to (if (!hasLocationPermission()) "none"
                else if (precisePermission) "precise" else "approximate"),
            "providers" to activeProviders,
        )
        if (location != null) {
            payload["location_source"] = locationSource
            payload["location_age_ms"] = locationAgeMs(location)
            payload["precision_status"] = if (precisePermission && location.hasAccuracy() &&
                location.accuracy <= 100f) "precise" else "approximate_or_unknown"
            payload["gps"] = linkedMapOf<String, Any?>(
                "latitude" to location.latitude,
                "longitude" to location.longitude,
                "altitude" to (if (location.hasAltitude()) location.altitude else null),
                "horizontal_accuracy_m" to (if (location.hasAccuracy()) location.accuracy.toDouble() else null),
            )
        }
        if (geocodeStatus != null) payload["geocode_status"] = geocodeStatus
        if (detail != null) payload[if (status == "ok") "geocode_detail" else "detail"] = detail
        if (address != null) {
            payload["address"] = mapOf(
                "country" to address.countryName,
                "country_code" to address.countryCode,
                "state_province" to address.adminArea,
                "county" to address.subAdminArea,
                "city" to address.locality,
                "district" to address.subLocality,
                "street" to address.thoroughfare,
                "street_number" to address.subThoroughfare,
                "postal_code" to address.postalCode,
            )
        }
        result.success(payload)
        bestLocation = null
        bestLocationSource = null
        activeProviders = emptyList()
    }
}
