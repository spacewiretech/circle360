import Foundation
import CoreLocation
import UIKit

/// Owns CoreLocation and the 10-second upload cadence.
///
/// The cadence is driven by a repeating timer rather than by delegate callbacks. CoreLocation only
/// calls `didUpdateLocations` when the fix actually changes, so a stationary device would stop
/// reporting altogether if the delegate were the clock. The timer posts the most recent fix on a
/// fixed heartbeat, which matches how Android's fused provider behaves.
///
/// The timer is safe in the background because `allowsBackgroundLocationUpdates` with active
/// location updates keeps the app running rather than suspended.
final class LocationTracker: NSObject, CLLocationManagerDelegate {

    static let shared = LocationTracker()

    private let manager = CLLocationManager()
    private var latestLocation: CLLocation?
    private var uploadTimer: Timer?
    private var authContinuation: ((String) -> Void)?
    private var wantsAlwaysUpgrade = false

    private let interval: TimeInterval = 10

    /// Pushed to the Flutter EventChannel while the UI happens to be alive.
    var onUpdate: (() -> Void)?

    private override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = kCLDistanceFilterNone
        // Without this iOS silently pauses updates when it decides you've stopped moving, and it
        // does not reliably resume them.
        manager.pausesLocationUpdatesAutomatically = false
        manager.activityType = .other
    }

    // MARK: - Permissions

    var permissionState: String {
        let status: CLAuthorizationStatus
        if #available(iOS 14.0, *) {
            status = manager.authorizationStatus
        } else {
            status = CLLocationManager.authorizationStatus()
        }
        switch status {
        case .notDetermined: return "notRequested"
        case .restricted, .denied: return "deniedForever"
        case .authorizedWhenInUse: return "whileInUse"
        case .authorizedAlways: return "always"
        @unknown default: return "denied"
        }
    }

    /// Staged: When-In-Use first. iOS refuses to show the Always prompt before that is granted.
    func requestPermissions(completion: @escaping (String) -> Void) {
        let current = permissionState
        if current == "notRequested" {
            authContinuation = completion
            manager.requestWhenInUseAuthorization()
        } else if current == "whileInUse" {
            requestAlwaysUpgrade(completion: completion)
        } else {
            completion(current)
        }
    }

    /// The Always upgrade. iOS may defer this prompt and show it later on its own schedule, so the
    /// UI keeps offering a Settings route as a fallback.
    func requestAlwaysUpgrade(completion: @escaping (String) -> Void) {
        guard permissionState == "whileInUse" else {
            completion(permissionState)
            return
        }
        wantsAlwaysUpgrade = true
        authContinuation = completion
        manager.requestAlwaysAuthorization()
        // The prompt may never fire a callback if iOS defers it; don't leave Dart hanging.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self = self, self.authContinuation != nil else { return }
            let done = self.authContinuation
            self.authContinuation = nil
            done?(self.permissionState)
        }
    }

    // MARK: - Tracking

    @discardableResult
    func start() -> Bool {
        let state = permissionState
        guard state == "whileInUse" || state == "always" else { return false }

        TrackingState.isTracking = true

        // Legal under When-In-Use as well as Always (the difference is that When-In-Use shows the
        // blue status bar indicator). Requires the `location` background mode — it throws without it.
        manager.allowsBackgroundLocationUpdates = true

        manager.startUpdatingLocation()

        // Significant Location Change is the ONLY mechanism that relaunches a force-quit app.
        // It fires roughly every 500m / 5 minutes, which is far coarser than our 10s cadence — it
        // exists purely to wake us back up so `startUpdatingLocation` can resume.
        if state == "always" && CLLocationManager.significantLocationChangeMonitoringAvailable() {
            manager.startMonitoringSignificantLocationChanges()
        }

        startUploadTimer()

        NSLog("Loc360: tracking started (auth=\(state))")
        return true
    }

    private func startUploadTimer() {
        guard uploadTimer == nil else { return } // start() is idempotent

        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.uploadLatest()
        }
        // .common keeps it firing while the user is scrolling the UI.
        RunLoop.main.add(timer, forMode: .common)
        uploadTimer = timer
    }

    private func uploadLatest() {
        guard TrackingState.isTracking, let location = latestLocation else { return }
        NSLog("Loc360: uploading \(location.coordinate.latitude),\(location.coordinate.longitude) ±\(location.horizontalAccuracy)m")
        LocationUploader.upload(location)
    }

    func stop() {
        TrackingState.isTracking = false
        manager.stopUpdatingLocation()
        manager.stopMonitoringSignificantLocationChanges()
        if manager.allowsBackgroundLocationUpdates {
            manager.allowsBackgroundLocationUpdates = false
        }
        uploadTimer?.invalidate()
        uploadTimer = nil
        latestLocation = nil
        NSLog("Loc360: tracking stopped")
    }

    /// Called from `didFinishLaunchingWithOptions` when iOS relaunched us for a location event.
    func resumeIfNeeded() {
        guard TrackingState.isTracking else { return }
        NSLog("Loc360: resuming tracking after relaunch")
        start()
    }

    // MARK: - CLLocationManagerDelegate

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }

        // Record only — the timer decides when to upload, so cadence holds even while stationary.
        let isFirstFix = latestLocation == nil
        latestLocation = location
        TrackingState.recordFix(location)
        onUpdate?()

        NSLog("Loc360: fix \(location.coordinate.latitude),\(location.coordinate.longitude) ±\(location.horizontalAccuracy)m")

        // Don't make the user wait a full interval for the first upload after starting.
        if isFirstFix { uploadLatest() }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        NSLog("Loc360: location error: \(error.localizedDescription)")
    }

    @available(iOS 14.0, *)
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        handleAuthorizationChange()
    }

    // iOS 13 fallback — the app's deployment target is 13.0.
    func locationManager(
        _ manager: CLLocationManager,
        didChangeAuthorization status: CLAuthorizationStatus
    ) {
        if #available(iOS 14.0, *) { return } // the modern callback already handled it
        handleAuthorizationChange()
    }

    private func handleAuthorizationChange() {
        let state = permissionState
        // This callback also fires once as soon as the delegate is set, so "we asked for this"
        // has to be distinguished from "we were merely told the current value".
        let wasRequesting = authContinuation != nil
        NSLog("Loc360: authorization changed -> \(state)")

        if let continuation = authContinuation {
            authContinuation = nil
            // When-In-Use just landed and we haven't asked for Always yet: chain straight into it.
            if state == "whileInUse" && !wantsAlwaysUpgrade {
                requestAlwaysUpgrade(completion: continuation)
            } else {
                wantsAlwaysUpgrade = false
                continuation(state)
            }
        }

        let canTrack = state == "whileInUse" || state == "always"

        if canTrack && wasRequesting {
            // Per the requirement, tracking begins the moment permission lands.
            start()
        } else if canTrack && TrackingState.isTracking {
            // Already-authorised cold start: resume, but only because tracking was left on.
            // Without this guard a plain launch would override the user's Stop.
            start()
        } else if !canTrack && TrackingState.isTracking {
            // Permission revoked from Settings while we were running.
            stop()
        }
        onUpdate?()
    }
}
