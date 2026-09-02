import Foundation
import CoreLocation

/// Posts a fix to the `ingest-location` Edge Function.
///
/// There is no offline queue, and that is the right call rather than a shortcut — the backend
/// keeps only the latest position per user, so a fix buffered through an outage is worthless the
/// moment the next one arrives ten seconds later. A failure is counted and dropped.
enum LocationUploader {

    private static let iso8601: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        // Timeouts stay under the 10s cadence so a dead network can't pile up requests.
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 12
        return URLSession(configuration: config)
    }()

    static func upload(_ location: CLLocation) {
        // No session means no upload. Posting anonymously would be worse than doing nothing:
        // the position could not be attributed to anyone, and it would still leave the device.
        guard let upload = TrackingState.upload else {
            NSLog("Loc360: skipping upload — not signed in")
            return
        }
        guard let url = URL(string: upload.endpoint) else { return }

        let payload: [String: Any] = [
            "device_id": TrackingState.deviceId,
            "latitude": location.coordinate.latitude,
            "longitude": location.coordinate.longitude,
            "accuracy": location.horizontalAccuracy,
            "speed": max(location.speed, 0),
            "altitude": location.altitude,
            "timestamp": iso8601.string(from: location.timestamp),
            "platform": "ios",
        ]

        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        // Supabase needs both: `apikey` gets the request past the gateway, and the bearer token
        // is the app's own session, which the function resolves to a user.
        if !upload.apiKey.isEmpty {
            request.setValue(upload.apiKey, forHTTPHeaderField: "apikey")
        }
        request.setValue("Bearer \(upload.token)", forHTTPHeaderField: "Authorization")
        request.httpBody = body

        session.dataTask(with: request) { _, response, error in
            if let error = error {
                TrackingState.recordUploadFailure(error.localizedDescription)
                NSLog("Loc360: POST failed: \(error.localizedDescription)")
                return
            }
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch code {
            case 200...299:
                TrackingState.recordUploadSuccess()
                // Only now does this position become the one the gate measures from.
                TrackingState.recordSent(location)
                NSLog("Loc360: POST \(code) ok")

            // The session was revoked or the subscription lapsed. Either way this device has no
            // business broadcasting any more, and nothing else will ever tell it so — the UI may
            // have been gone for days.
            case 401, 403:
                NSLog("Loc360: POST \(code) — stopping tracking")
                TrackingState.recordUploadFailure("HTTP \(code)")
                TrackingState.clearUpload()
                DispatchQueue.main.async { LocationTracker.shared.stop() }

            default:
                TrackingState.recordUploadFailure("HTTP \(code)")
                NSLog("Loc360: POST failed with HTTP \(code)")
            }
        }.resume()
    }
}
