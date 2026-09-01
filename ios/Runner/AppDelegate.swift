import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {

  private static let methodChannelName = "loc360/location"
  private static let eventChannelName = "loc360/events"

  private var eventSink: FlutterEventSink?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // A non-nil `.location` key means iOS relaunched us in the background for a location event —
    // this is the entire force-quit / reboot recovery path. The Flutter UI is not running here, so
    // everything from this point is handled natively.
    if launchOptions?[.location] != nil {
      NSLog("Loc360: relaunched by CoreLocation")
      LocationTracker.shared.resumeIfNeeded()
    } else if TrackingState.isTracking {
      // Normal cold start while tracking was left on.
      LocationTracker.shared.resumeIfNeeded()
    }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    // `applicationRegistrar` is the documented route to app-level channels on the implicit engine.
    let messenger = engineBridge.applicationRegistrar.messenger()

    FlutterMethodChannel(name: Self.methodChannelName, binaryMessenger: messenger)
      .setMethodCallHandler { [weak self] call, result in
        self?.handle(call, result: result)
      }

    FlutterEventChannel(name: Self.eventChannelName, binaryMessenger: messenger)
      .setStreamHandler(self)
  }

  // MARK: - Method channel

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "getStatus":
      result(status())

    case "requestPermissions":
      LocationTracker.shared.requestPermissions { [weak self] _ in
        result(self?.status() ?? [:])
      }

    case "requestBackgroundPermission":
      // On iOS "background" means upgrading When-In-Use to Always.
      LocationTracker.shared.requestAlwaysUpgrade { [weak self] _ in
        result(self?.status() ?? [:])
      }

    // Dart hands down the session token at sign-in. The uploader cannot ask for it later: iOS can
    // relaunch this process with no Flutter engine attached, so this is the only route it has.
    case "configureUpload":
      let args = call.arguments as? [String: Any]
      guard
        let endpoint = args?["endpoint"] as? String, !endpoint.isEmpty,
        let token = args?["token"] as? String, !token.isEmpty
      else {
        result(FlutterError(code: "invalid_args", message: "endpoint and token are required", details: nil))
        return
      }
      TrackingState.setUpload(
        endpoint: endpoint,
        apiKey: args?["apiKey"] as? String ?? "",
        token: token
      )
      result(true)

    case "clearUpload":
      TrackingState.clearUpload()
      result(true)

    case "startTracking":
      result(LocationTracker.shared.start())

    case "stopTracking":
      LocationTracker.shared.stop()
      result(true)

    case "openAppSettings":
      if let url = URL(string: UIApplication.openSettingsURLString) {
        UIApplication.shared.open(url)
      }
      result(nil)

    case "requestIgnoreBatteryOptimizations":
      // Android-only concept; iOS has no equivalent whitelist.
      result(false)

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func status() -> [String: Any] {
    var snapshot = TrackingState.snapshot()
    snapshot["permission"] = LocationTracker.shared.permissionState
    // Strip nils so the map crosses the channel cleanly.
    return snapshot.compactMapValues { $0 }
  }
}

// MARK: - Event channel

extension AppDelegate: FlutterStreamHandler {

  func onListen(
    withArguments arguments: Any?,
    eventSink events: @escaping FlutterEventSink
  ) -> FlutterError? {
    eventSink = events
    LocationTracker.shared.onUpdate = { [weak self] in
      guard let self = self, let sink = self.eventSink else { return }
      DispatchQueue.main.async { sink(self.status()) }
    }
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    LocationTracker.shared.onUpdate = nil
    eventSink = nil
    return nil
  }
}
