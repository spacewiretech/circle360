package com.spacewire.circle360

import android.content.Context
import android.location.Location
import java.util.UUID

/**
 * SharedPreferences-backed state shared by the activity, the service and the boot receiver.
 *
 * The service keeps running after the Flutter engine is gone, so this is the only place where
 * "is tracking on" and the upload counters survive. The UI reads it back on resume instead of
 * assuming a fresh start.
 */
object TrackingState {

    private const val PREFS = "loc360_state"

    private const val KEY_TRACKING = "is_tracking"
    private const val KEY_DEVICE_ID = "device_id"
    private const val KEY_ENDPOINT = "upload_endpoint"
    private const val KEY_API_KEY = "upload_api_key"
    private const val KEY_TOKEN = "upload_token"
    private const val KEY_LAST_LAT = "last_lat"
    private const val KEY_LAST_LNG = "last_lng"
    private const val KEY_LAST_ACCURACY = "last_accuracy"
    private const val KEY_LAST_FIX_AT = "last_fix_at"
    private const val KEY_LAST_SUCCESS_AT = "last_success_at"
    private const val KEY_SUCCESS_COUNT = "success_count"
    private const val KEY_FAILURE_COUNT = "failure_count"
    private const val KEY_LAST_ERROR = "last_error"

    private fun prefs(context: Context) =
        context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    fun isTracking(context: Context): Boolean = prefs(context).getBoolean(KEY_TRACKING, false)

    fun setTracking(context: Context, tracking: Boolean) {
        prefs(context).edit().putBoolean(KEY_TRACKING, tracking).apply()
    }

    /** Install-scoped id, reported alongside each fix so multiple devices can be told apart. */
    fun deviceId(context: Context): String {
        val p = prefs(context)
        return p.getString(KEY_DEVICE_ID, null) ?: UUID.randomUUID().toString().also {
            p.edit().putString(KEY_DEVICE_ID, it).apply()
        }
    }

    /**
     * Where uploads go and what authenticates them.
     *
     * The service outlives the Flutter engine, so it cannot ask Dart for the session token when
     * it needs one — Dart pushes it here at sign-in instead, and this is the only copy that
     * survives a force-quit or a reboot.
     */
    data class Upload(val endpoint: String, val apiKey: String, val token: String)

    fun setUpload(context: Context, endpoint: String, apiKey: String, token: String) {
        prefs(context).edit()
            .putString(KEY_ENDPOINT, endpoint)
            .putString(KEY_API_KEY, apiKey)
            .putString(KEY_TOKEN, token)
            .apply()
    }

    fun clearUpload(context: Context) {
        prefs(context).edit()
            .remove(KEY_ENDPOINT)
            .remove(KEY_API_KEY)
            .remove(KEY_TOKEN)
            .apply()
    }

    /** Null until Dart has signed in. A null here means "do not upload", never "upload anonymously". */
    fun upload(context: Context): Upload? {
        val p = prefs(context)
        val endpoint = p.getString(KEY_ENDPOINT, null)
        val token = p.getString(KEY_TOKEN, null)
        if (endpoint.isNullOrBlank() || token.isNullOrBlank()) return null
        return Upload(endpoint, p.getString(KEY_API_KEY, null).orEmpty(), token)
    }

    fun recordFix(context: Context, location: Location) {
        prefs(context).edit()
            .putFloat(KEY_LAST_LAT, location.latitude.toFloat())
            .putFloat(KEY_LAST_LNG, location.longitude.toFloat())
            .putFloat(KEY_LAST_ACCURACY, location.accuracy)
            .putLong(KEY_LAST_FIX_AT, System.currentTimeMillis())
            // Floats lose precision past ~7 digits, so keep the authoritative values as strings.
            .putString("last_lat_exact", location.latitude.toString())
            .putString("last_lng_exact", location.longitude.toString())
            .apply()
    }

    fun recordUploadSuccess(context: Context) {
        val p = prefs(context)
        p.edit()
            .putLong(KEY_LAST_SUCCESS_AT, System.currentTimeMillis())
            .putInt(KEY_SUCCESS_COUNT, p.getInt(KEY_SUCCESS_COUNT, 0) + 1)
            .remove(KEY_LAST_ERROR)
            .apply()
    }

    fun recordUploadFailure(context: Context, error: String) {
        val p = prefs(context)
        p.edit()
            .putInt(KEY_FAILURE_COUNT, p.getInt(KEY_FAILURE_COUNT, 0) + 1)
            .putString(KEY_LAST_ERROR, error.take(200))
            .apply()
    }

    /** Snapshot in the exact shape the Dart layer expects from `getStatus()`. */
    fun snapshot(context: Context): Map<String, Any?> {
        val p = prefs(context)
        val fixAt = p.getLong(KEY_LAST_FIX_AT, 0L)
        return mapOf(
            "isTracking" to p.getBoolean(KEY_TRACKING, false),
            "latitude" to p.getString("last_lat_exact", null)?.toDoubleOrNull(),
            "longitude" to p.getString("last_lng_exact", null)?.toDoubleOrNull(),
            "accuracy" to if (fixAt > 0) p.getFloat(KEY_LAST_ACCURACY, 0f).toDouble() else null,
            "lastFixAt" to if (fixAt > 0) fixAt else null,
            "lastSuccessAt" to p.getLong(KEY_LAST_SUCCESS_AT, 0L).takeIf { it > 0 },
            "successCount" to p.getInt(KEY_SUCCESS_COUNT, 0),
            "failureCount" to p.getInt(KEY_FAILURE_COUNT, 0),
            "lastError" to p.getString(KEY_LAST_ERROR, null),
            // Lets the UI distinguish "tracking is off" from "tracking is on but going nowhere",
            // which otherwise look identical from Dart.
            "uploadConfigured" to (upload(context) != null),
        )
    }
}
