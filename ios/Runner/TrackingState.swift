import Foundation
import CoreLocation

/// UserDefaults-backed mirror of the Android `TrackingState`.
///
/// iOS can relaunch the app in the background after a force-quit, at which point nothing from the
/// previous process survives except this. `isTracking` is what tells the relaunched process that
/// it should resume rather than sit idle.
enum TrackingState {

    private static let defaults = UserDefaults.standard

    private enum Key {
        static let tracking = "loc360.isTracking"
        static let deviceId = "loc360.deviceId"
        static let lat = "loc360.lastLat"
        static let lng = "loc360.lastLng"
        static let accuracy = "loc360.lastAccuracy"
        static let fixAt = "loc360.lastFixAt"
        static let successAt = "loc360.lastSuccessAt"
        static let successCount = "loc360.successCount"
        static let failureCount = "loc360.failureCount"
        static let lastError = "loc360.lastError"
        static let endpoint = "loc360.uploadEndpoint"
        static let apiKey = "loc360.uploadApiKey"
        static let token = "loc360.uploadToken"
    }

    /// Where uploads go and what authenticates them.
    ///
    /// iOS can relaunch this process in the background with no Flutter engine attached, so the
    /// uploader cannot ask Dart for the session token when it needs one. Dart pushes it here at
    /// sign-in, and this is the only copy that survives a force-quit.
    struct Upload {
        let endpoint: String
        let apiKey: String
        let token: String
    }

    static func setUpload(endpoint: String, apiKey: String, token: String) {
        defaults.set(endpoint, forKey: Key.endpoint)
        defaults.set(apiKey, forKey: Key.apiKey)
        defaults.set(token, forKey: Key.token)
    }

    static func clearUpload() {
        defaults.removeObject(forKey: Key.endpoint)
        defaults.removeObject(forKey: Key.apiKey)
        defaults.removeObject(forKey: Key.token)
    }

    /// Nil until Dart has signed in. Nil means "do not upload", never "upload anonymously".
    static var upload: Upload? {
        guard
            let endpoint = defaults.string(forKey: Key.endpoint), !endpoint.isEmpty,
            let token = defaults.string(forKey: Key.token), !token.isEmpty
        else { return nil }
        return Upload(
            endpoint: endpoint,
            apiKey: defaults.string(forKey: Key.apiKey) ?? "",
            token: token
        )
    }

    static var isTracking: Bool {
        get { defaults.bool(forKey: Key.tracking) }
        set { defaults.set(newValue, forKey: Key.tracking) }
    }

    /// Install-scoped id so the dummy backend can tell devices apart.
    static var deviceId: String {
        if let existing = defaults.string(forKey: Key.deviceId) { return existing }
        let generated = UUID().uuidString
        defaults.set(generated, forKey: Key.deviceId)
        return generated
    }

    static func recordFix(_ location: CLLocation) {
        defaults.set(location.coordinate.latitude, forKey: Key.lat)
        defaults.set(location.coordinate.longitude, forKey: Key.lng)
        defaults.set(location.horizontalAccuracy, forKey: Key.accuracy)
        defaults.set(Date().timeIntervalSince1970 * 1000, forKey: Key.fixAt)
    }

    static func recordUploadSuccess() {
        defaults.set(Date().timeIntervalSince1970 * 1000, forKey: Key.successAt)
        defaults.set(defaults.integer(forKey: Key.successCount) + 1, forKey: Key.successCount)
        defaults.removeObject(forKey: Key.lastError)
    }

    static func recordUploadFailure(_ error: String) {
        defaults.set(defaults.integer(forKey: Key.failureCount) + 1, forKey: Key.failureCount)
        defaults.set(String(error.prefix(200)), forKey: Key.lastError)
    }

    /// Snapshot in the exact shape the Dart layer expects from `getStatus()`.
    static func snapshot() -> [String: Any?] {
        let fixAt = defaults.double(forKey: Key.fixAt)
        let successAt = defaults.double(forKey: Key.successAt)
        return [
            "isTracking": isTracking,
            "latitude": fixAt > 0 ? defaults.double(forKey: Key.lat) : nil,
            "longitude": fixAt > 0 ? defaults.double(forKey: Key.lng) : nil,
            "accuracy": fixAt > 0 ? defaults.double(forKey: Key.accuracy) : nil,
            "lastFixAt": fixAt > 0 ? Int(fixAt) : nil,
            "lastSuccessAt": successAt > 0 ? Int(successAt) : nil,
            "successCount": defaults.integer(forKey: Key.successCount),
            "failureCount": defaults.integer(forKey: Key.failureCount),
            "lastError": defaults.string(forKey: Key.lastError),
            // No equivalent of Android's battery-optimization whitelist on iOS.
            "batteryOptimized": false,
            // Lets the UI distinguish "tracking is off" from "tracking is on but going nowhere".
            "uploadConfigured": upload != nil,
        ]
    }
}
