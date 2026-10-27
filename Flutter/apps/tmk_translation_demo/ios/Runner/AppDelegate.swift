import CoreLocation
import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private let sauceLocationProbe = SauceLocationProbe()

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let channel = FlutterMethodChannel(
      name: "tmk.sauce.deviceEnvironment",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    channel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "read" else {
        result(FlutterMethodNotImplemented)
        return
      }
      self?.sauceLocationProbe.read(result)
    }
  }
}

private final class SauceLocationProbe: NSObject, CLLocationManagerDelegate {
  private var manager: CLLocationManager?
  private var completion: FlutterResult?
  private var timeout: DispatchWorkItem?
  private var geocoder: CLGeocoder?
  private var requestedAuthorization = false
  private var requestedLocation = false
  private var geocoding = false

  func read(_ result: @escaping FlutterResult) {
    guard completion == nil else {
      result(FlutterError(code: "busy", message: "Location request already running", details: nil))
      return
    }
    completion = result
    guard CLLocationManager.locationServicesEnabled() else {
      finish(status: "services_disabled")
      return
    }
    let manager = CLLocationManager()
    manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    manager.delegate = self
    self.manager = manager
    let timeout = DispatchWorkItem { [weak self] in self?.finish(status: "timeout") }
    self.timeout = timeout
    DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: timeout)
    handleAuthorization(manager)
  }

  func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    handleAuthorization(manager)
  }

  private func handleAuthorization(_ manager: CLLocationManager) {
    guard completion != nil else { return }
    switch manager.authorizationStatus {
    case .notDetermined:
      if !requestedAuthorization {
        requestedAuthorization = true
        manager.requestWhenInUseAuthorization()
      }
    case .authorizedWhenInUse, .authorizedAlways:
      if !requestedLocation {
        requestedLocation = true
        manager.requestLocation()
      }
    case .denied:
      finish(status: "permission_denied")
    case .restricted:
      finish(status: "permission_restricted")
    @unknown default:
      finish(status: "authorization_unknown")
    }
  }

  func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
    guard !geocoding else { return }
    guard let location = locations.last,
          location.horizontalAccuracy >= 0,
          CLLocationCoordinate2DIsValid(location.coordinate) else {
      finish(status: "invalid_location")
      return
    }
    geocoding = true
    manager.delegate = nil
    self.manager = nil
    timeout?.cancel()
    let geocoder = CLGeocoder()
    self.geocoder = geocoder
    let geocodeTimeout = DispatchWorkItem { [weak self] in
      self?.finish(status: "ok", location: location, geocodeStatus: "timeout")
    }
    timeout = geocodeTimeout
    DispatchQueue.main.asyncAfter(deadline: .now() + 12, execute: geocodeTimeout)
    geocoder.reverseGeocodeLocation(location, preferredLocale: Locale.current) { [weak self] placemarks, error in
      guard self?.completion != nil else { return }
      if let placemark = placemarks?.first {
        self?.finish(status: "ok", location: location, placemark: placemark, geocodeStatus: "ok")
      } else {
        self?.finish(
          status: "ok",
          location: location,
          geocodeStatus: error == nil ? "no_result" : "error",
          geocodeDetail: error?.localizedDescription
        )
      }
    }
  }

  func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
    guard !geocoding else { return }
    finish(status: "location_error", detail: error.localizedDescription)
  }

  private func finish(
    status: String,
    location: CLLocation? = nil,
    detail: String? = nil,
    placemark: CLPlacemark? = nil,
    geocodeStatus: String? = nil,
    geocodeDetail: String? = nil
  ) {
    guard let completion else { return }
    self.completion = nil
    timeout?.cancel()
    timeout = nil
    geocoder?.cancelGeocode()
    geocoder = nil
    manager?.delegate = nil
    manager = nil
    requestedAuthorization = false
    requestedLocation = false
    geocoding = false
    var payload: [String: Any] = [
      "status": status,
      "locale": Locale.current.identifier,
      "timeZone": TimeZone.current.identifier,
    ]
    if let location {
      payload["gps"] = [
        "latitude": location.coordinate.latitude,
        "longitude": location.coordinate.longitude,
        "altitude": location.altitude,
        "horizontal_accuracy_m": location.horizontalAccuracy,
      ]
    }
    if let geocodeStatus { payload["geocode_status"] = geocodeStatus }
    if let geocodeDetail { payload["geocode_detail"] = geocodeDetail }
    if let placemark {
      var address: [String: String] = [:]
      let fields: [(String, String?)] = [
        ("country", placemark.country),
        ("country_code", placemark.isoCountryCode),
        ("state_province", placemark.administrativeArea),
        ("county", placemark.subAdministrativeArea),
        ("city", placemark.locality),
        ("district", placemark.subLocality),
        ("street", placemark.thoroughfare),
        ("street_number", placemark.subThoroughfare),
        ("postal_code", placemark.postalCode),
      ]
      for (key, value) in fields {
        if let value, !value.isEmpty { address[key] = value }
      }
      payload["address"] = address
    }
    if let detail { payload["detail"] = detail }
    completion(payload)
  }
}
