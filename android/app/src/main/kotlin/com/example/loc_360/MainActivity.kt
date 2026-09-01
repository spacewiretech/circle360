package com.example.loc_360

import android.Manifest
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    companion object {
        private const val METHOD_CHANNEL = "loc360/location"
        private const val EVENT_CHANNEL = "loc360/events"

        private const val REQ_NOTIFICATIONS = 1001
        private const val REQ_LOCATION = 1002
        private const val REQ_BACKGROUND = 1003
    }

    private var pendingResult: MethodChannel.Result? = null
    private var eventSink: EventChannel.EventSink? = null
    private var updateReceiver: BroadcastReceiver? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, METHOD_CHANNEL)
            .setMethodCallHandler { call, result -> onMethodCall(call, result) }

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, EVENT_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    eventSink = events
                    registerUpdateReceiver()
                }

                override fun onCancel(arguments: Any?) {
                    unregisterUpdateReceiver()
                    eventSink = null
                }
            })
    }

    private fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "getStatus" -> result.success(status())

            "requestPermissions" -> {
                pendingResult = result
                requestNextPermission()
            }

            "requestBackgroundPermission" -> {
                pendingResult = result
                requestBackgroundLocation()
            }

            // Dart hands down the session token at sign-in. The service cannot ask for it later:
            // it outlives the Flutter engine, so this is the only route the credential has.
            "configureUpload" -> {
                val endpoint = call.argument<String>("endpoint")
                val token = call.argument<String>("token")
                if (endpoint.isNullOrBlank() || token.isNullOrBlank()) {
                    result.error("invalid_args", "endpoint and token are required", null)
                } else {
                    TrackingState.setUpload(
                        this,
                        endpoint,
                        call.argument<String>("apiKey").orEmpty(),
                        token,
                    )
                    result.success(true)
                }
            }

            "clearUpload" -> {
                TrackingState.clearUpload(this)
                result.success(true)
            }

            "startTracking" -> {
                if (!hasForegroundLocation()) {
                    result.success(false)
                } else {
                    LocationTrackingService.start(this)
                    result.success(true)
                }
            }

            "stopTracking" -> {
                LocationTrackingService.stop(this)
                TrackingState.setTracking(this, false)
                result.success(true)
            }

            "openAppSettings" -> {
                startActivity(
                    Intent(
                        Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                        Uri.fromParts("package", packageName, null),
                    )
                )
                result.success(null)
            }

            "requestIgnoreBatteryOptimizations" -> {
                result.success(requestIgnoreBatteryOptimizations())
            }

            else -> result.notImplemented()
        }
    }

    // ---------------------------------------------------------------- status

    private fun status(): Map<String, Any?> =
        TrackingState.snapshot(this) + mapOf(
            "permission" to permissionState(),
            "batteryOptimized" to isBatteryOptimized(),
        )

    /** Mirrors the Dart enum: notRequested / denied / deniedForever / whileInUse / always. */
    private fun permissionState(): String {
        if (!hasForegroundLocation()) {
            // A permanent denial is indistinguishable from "never asked" except that the system
            // stops showing a rationale after the user checks "don't ask again".
            val everAsked = getPreferences(Context.MODE_PRIVATE).getBoolean("asked_location", false)
            if (!everAsked) return "notRequested"
            return if (ActivityCompat.shouldShowRequestPermissionRationale(
                    this,
                    Manifest.permission.ACCESS_FINE_LOCATION,
                )
            ) "denied" else "deniedForever"
        }
        return if (hasBackgroundLocation()) "always" else "whileInUse"
    }

    private fun hasForegroundLocation() = ContextCompat.checkSelfPermission(
        this,
        Manifest.permission.ACCESS_FINE_LOCATION,
    ) == PackageManager.PERMISSION_GRANTED

    private fun hasBackgroundLocation(): Boolean {
        // Below Android 10 there is no separate background permission — foreground implies it.
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return true
        return ContextCompat.checkSelfPermission(
            this,
            Manifest.permission.ACCESS_BACKGROUND_LOCATION,
        ) == PackageManager.PERMISSION_GRANTED
    }

    // ----------------------------------------------------------- permissions

    /**
     * Staged flow: notifications first (so the service notification is actually visible), then
     * foreground location. Background location is deliberately NOT bundled here — Android 11+
     * refuses a combined request, and it needs its own rationale anyway.
     */
    private fun requestNextPermission() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            ActivityCompat.requestPermissions(
                this,
                arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                REQ_NOTIFICATIONS,
            )
            return
        }
        requestForegroundLocation()
    }

    private fun requestForegroundLocation() {
        if (hasForegroundLocation()) {
            resolvePending()
            return
        }
        getPreferences(Context.MODE_PRIVATE).edit().putBoolean("asked_location", true).apply()
        ActivityCompat.requestPermissions(
            this,
            arrayOf(
                Manifest.permission.ACCESS_FINE_LOCATION,
                Manifest.permission.ACCESS_COARSE_LOCATION,
            ),
            REQ_LOCATION,
        )
    }

    /**
     * Android 11+ removed "Allow all the time" from the runtime dialog — the only way to grant it
     * is the app's settings page, so we send the user there instead of firing a request that the
     * system would silently deny.
     */
    private fun requestBackgroundLocation() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q || hasBackgroundLocation()) {
            resolvePending()
            return
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            startActivity(
                Intent(
                    Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                    Uri.fromParts("package", packageName, null),
                )
            )
            resolvePending()
        } else {
            ActivityCompat.requestPermissions(
                this,
                arrayOf(Manifest.permission.ACCESS_BACKGROUND_LOCATION),
                REQ_BACKGROUND,
            )
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        when (requestCode) {
            // Notifications are best-effort: a refusal shouldn't block location tracking.
            REQ_NOTIFICATIONS -> requestForegroundLocation()

            REQ_LOCATION -> {
                if (hasForegroundLocation()) {
                    // Per the requirement, tracking begins the moment permission lands.
                    LocationTrackingService.start(this)
                }
                resolvePending()
            }

            REQ_BACKGROUND -> resolvePending()
        }
    }

    private fun resolvePending() {
        pendingResult?.success(status())
        pendingResult = null
    }

    // ------------------------------------------------------------ battery

    private fun isBatteryOptimized(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return false
        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
        return !pm.isIgnoringBatteryOptimizations(packageName)
    }

    @Suppress("BatteryLife") // Continuous tracking is the app's entire purpose.
    private fun requestIgnoreBatteryOptimizations(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M || !isBatteryOptimized()) return false
        return try {
            startActivity(
                Intent(
                    Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                    Uri.parse("package:$packageName"),
                )
            )
            true
        } catch (e: Exception) {
            // Some OEM ROMs ship without this screen; fall back to the app settings page.
            startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
            true
        }
    }

    // ------------------------------------------------------------- events

    private fun registerUpdateReceiver() {
        if (updateReceiver != null) return
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                eventSink?.success(status())
            }
        }
        updateReceiver = receiver
        ContextCompat.registerReceiver(
            this,
            receiver,
            IntentFilter(LocationTrackingService.BROADCAST_UPDATE),
            ContextCompat.RECEIVER_NOT_EXPORTED,
        )
    }

    private fun unregisterUpdateReceiver() {
        updateReceiver?.let { runCatching { unregisterReceiver(it) } }
        updateReceiver = null
    }

    override fun onDestroy() {
        unregisterUpdateReceiver()
        super.onDestroy()
    }
}
