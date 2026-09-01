package com.spacewire.circle360

import android.content.Context
import android.location.Location
import android.util.Log
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone
import java.util.concurrent.Executors

/**
 * Posts a fix to the `ingest-location` Edge Function using HttpURLConnection on a single
 * background thread.
 *
 * Deliberately dependency-free: the only third-party library in the app is Play Services location.
 *
 * There is no offline queue, and that is the right call rather than a shortcut — the backend
 * keeps only the latest position per user, so a fix buffered through an outage is worthless the
 * moment the next one arrives ten seconds later. A failure is counted and dropped.
 */
object LocationUploader {

    private const val TAG = "Loc360"

    private val executor = Executors.newSingleThreadExecutor()

    private val iso8601 = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss'Z'", Locale.US).apply {
        timeZone = TimeZone.getTimeZone("UTC")
    }

    fun upload(context: Context, location: Location) {
        val appContext = context.applicationContext

        // No session means no upload. Posting anonymously would be worse than doing nothing:
        // the position could not be attributed to anyone, and it would still leave the device.
        val upload = TrackingState.upload(appContext)
        if (upload == null) {
            Log.d(TAG, "skipping upload — not signed in")
            return
        }

        val body = buildPayload(appContext, location)

        executor.execute {
            var connection: HttpURLConnection? = null
            try {
                connection = (URL(upload.endpoint).openConnection() as HttpURLConnection).apply {
                    requestMethod = "POST"
                    // Timeouts must stay under the 10s cadence so a dead network can't pile up work.
                    connectTimeout = 8_000
                    readTimeout = 8_000
                    doOutput = true
                    setRequestProperty("Content-Type", "application/json; charset=utf-8")
                    // Supabase needs both: `apikey` gets the request past the gateway, and the
                    // bearer token is the app's own session, which the function resolves to a user.
                    if (upload.apiKey.isNotEmpty()) setRequestProperty("apikey", upload.apiKey)
                    setRequestProperty("Authorization", "Bearer ${upload.token}")
                }

                connection.outputStream.use { it.write(body.toByteArray(Charsets.UTF_8)) }

                when (val code = connection.responseCode) {
                    in 200..299 -> {
                        TrackingState.recordUploadSuccess(appContext)
                        Log.d(TAG, "POST $code ok")
                    }

                    // The session was revoked or the subscription lapsed. Either way this device
                    // has no business broadcasting any more, and nothing else will ever tell it
                    // so — the UI may have been gone for days.
                    401, 403 -> {
                        Log.w(TAG, "POST $code — stopping tracking")
                        TrackingState.recordUploadFailure(appContext, "HTTP $code")
                        TrackingState.clearUpload(appContext)
                        LocationTrackingService.stop(appContext)
                    }

                    else -> {
                        TrackingState.recordUploadFailure(appContext, "HTTP $code")
                        Log.w(TAG, "POST failed with HTTP $code")
                    }
                }
            } catch (e: Exception) {
                TrackingState.recordUploadFailure(appContext, e.message ?: e.javaClass.simpleName)
                Log.w(TAG, "POST failed: ${e.message}")
            } finally {
                connection?.disconnect()
            }
        }
    }

    private fun buildPayload(context: Context, location: Location): String =
        JSONObject().apply {
            put("device_id", TrackingState.deviceId(context))
            put("latitude", location.latitude)
            put("longitude", location.longitude)
            put("accuracy", location.accuracy.toDouble())
            put("speed", location.speed.toDouble())
            put("altitude", location.altitude)
            put("timestamp", iso8601.format(Date(location.time)))
            put("platform", "android")
        }.toString()
}
