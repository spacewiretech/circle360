package com.example.loc_360

import android.app.AlarmManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.location.Location
import android.os.Build
import android.os.IBinder
import android.os.SystemClock
import android.util.Log
import com.google.android.gms.location.FusedLocationProviderClient
import com.google.android.gms.location.LocationCallback
import com.google.android.gms.location.LocationRequest
import com.google.android.gms.location.LocationResult
import com.google.android.gms.location.LocationServices
import com.google.android.gms.location.Priority

/**
 * Foreground service that owns the 10-second tracking loop.
 *
 * This runs independently of the Flutter engine: after the task is swiped away the Dart isolate is
 * gone but this service (and its uploads) keep going. That is the whole reason the cadence and the
 * HTTP call live in Kotlin rather than Dart.
 */
class LocationTrackingService : Service() {

    companion object {
        private const val TAG = "Loc360"
        private const val CHANNEL_ID = "loc360_tracking"
        private const val NOTIFICATION_ID = 4201

        const val ACTION_START = "com.example.loc_360.START"
        const val ACTION_STOP = "com.example.loc_360.STOP"

        private const val INTERVAL_MS = 10_000L

        /** Broadcast so the Flutter UI can live-update while it happens to be alive. */
        const val BROADCAST_UPDATE = "com.example.loc_360.LOCATION_UPDATE"

        fun start(context: Context) {
            val intent = Intent(context, LocationTrackingService::class.java)
                .setAction(ACTION_START)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            context.startService(
                Intent(context, LocationTrackingService::class.java).setAction(ACTION_STOP)
            )
        }
    }

    private lateinit var fusedClient: FusedLocationProviderClient
    private var callback: LocationCallback? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        fusedClient = LocationServices.getFusedLocationProviderClient(this)
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                stopTracking()
                return START_NOT_STICKY
            }
            else -> startTracking()
        }
        // START_STICKY asks the system to recreate us if we're killed for memory.
        return START_STICKY
    }

    private fun startTracking() {
        // Promote to foreground immediately. On Android 14+ the location type is mandatory and the
        // system kills the service if we don't call this within a few seconds of being started.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                buildNotification(),
                ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION,
            )
        } else {
            startForeground(NOTIFICATION_ID, buildNotification())
        }

        if (callback != null) return // already running; a duplicate start is a no-op

        TrackingState.setTracking(this, true)

        val request = LocationRequest.Builder(Priority.PRIORITY_HIGH_ACCURACY, INTERVAL_MS)
            .setMinUpdateIntervalMillis(INTERVAL_MS)
            .setWaitForAccurateLocation(false)
            .build()

        val cb = object : LocationCallback() {
            override fun onLocationResult(result: LocationResult) {
                result.lastLocation?.let { onNewFix(it) }
            }
        }
        callback = cb

        try {
            fusedClient.requestLocationUpdates(request, cb, mainLooper)
            Log.d(TAG, "tracking started (${INTERVAL_MS}ms interval)")
        } catch (e: SecurityException) {
            // Permission was revoked from Settings while the service was running.
            Log.e(TAG, "missing location permission: ${e.message}")
            stopTracking()
        }
    }

    private fun onNewFix(location: Location) {
        Log.d(TAG, "fix ${location.latitude},${location.longitude} ±${location.accuracy}m")
        TrackingState.recordFix(this, location)
        LocationUploader.upload(this, location)

        sendBroadcast(
            Intent(BROADCAST_UPDATE)
                .setPackage(packageName)
                .putExtra("latitude", location.latitude)
                .putExtra("longitude", location.longitude)
                .putExtra("accuracy", location.accuracy)
        )
    }

    private fun stopTracking() {
        callback?.let { fusedClient.removeLocationUpdates(it) }
        callback = null
        TrackingState.setTracking(this, false)
        Log.d(TAG, "tracking stopped")
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    /**
     * Stock Android keeps a foreground service alive through a swipe-away, but Xiaomi/Oppo/Vivo/
     * Huawei ROMs tear the whole process down. Scheduling a restart alarm here is what brings
     * tracking back on those devices.
     */
    override fun onTaskRemoved(rootIntent: Intent?) {
        if (TrackingState.isTracking(this)) {
            Log.d(TAG, "task removed while tracking — scheduling restart")
            val restart = PendingIntent.getBroadcast(
                this,
                0,
                Intent(this, BootReceiver::class.java).setAction(BootReceiver.ACTION_RESTART),
                PendingIntent.FLAG_ONE_SHOT or PendingIntent.FLAG_IMMUTABLE,
            )
            val alarms = getSystemService(Context.ALARM_SERVICE) as AlarmManager
            alarms.set(
                AlarmManager.ELAPSED_REALTIME_WAKEUP,
                SystemClock.elapsedRealtime() + 1_000L,
                restart,
            )
        }
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        callback?.let { fusedClient.removeLocationUpdates(it) }
        callback = null
        super.onDestroy()
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            "Location tracking",
            NotificationManager.IMPORTANCE_LOW, // LOW = no sound, still always visible
        ).apply {
            description = "Shown while your location is being tracked"
            setShowBadge(false)
        }
        (getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager)
            .createNotificationChannel(channel)
    }

    private fun buildNotification(): Notification {
        val openApp = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }

        return builder
            .setContentTitle("Location tracking active")
            .setContentText("Sending your location every 10 seconds")
            .setSmallIcon(android.R.drawable.ic_menu_mylocation)
            .setContentIntent(openApp)
            .setOngoing(true)
            .build()
    }
}
