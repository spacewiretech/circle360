package com.spacewire.circle360

import android.Manifest
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.util.Log
import androidx.core.content.ContextCompat

/**
 * Brings tracking back after the two events that would otherwise end it silently:
 * device reboot, and the restart alarm scheduled by [LocationTrackingService.onTaskRemoved].
 *
 * Only restarts when the user actually had tracking on — it never resurrects a session they stopped.
 */
class BootReceiver : BroadcastReceiver() {

    companion object {
        private const val TAG = "Loc360"
        const val ACTION_RESTART = "com.spacewire.circle360.RESTART_SERVICE"
    }

    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action
        val relevant = action == Intent.ACTION_BOOT_COMPLETED ||
            action == Intent.ACTION_LOCKED_BOOT_COMPLETED ||
            action == "android.intent.action.QUICKBOOT_POWERON" ||
            action == ACTION_RESTART
        if (!relevant) return

        if (!TrackingState.isTracking(context)) {
            Log.d(TAG, "$action received but tracking was off — ignoring")
            return
        }

        // Permission can be revoked while we were dead; starting a location FGS without it crashes.
        val fine = ContextCompat.checkSelfPermission(
            context,
            Manifest.permission.ACCESS_FINE_LOCATION,
        ) == PackageManager.PERMISSION_GRANTED

        if (!fine) {
            Log.w(TAG, "$action received but location permission is gone — clearing state")
            TrackingState.setTracking(context, false)
            return
        }

        // We're starting from the background here, which on Android 10+ additionally requires
        // background location for a `location`-typed foreground service.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q &&
            ContextCompat.checkSelfPermission(
                context,
                Manifest.permission.ACCESS_BACKGROUND_LOCATION,
            ) != PackageManager.PERMISSION_GRANTED
        ) {
            Log.w(TAG, "$action but no background location — cannot restart until app is opened")
            return
        }

        Log.d(TAG, "$action — restarting tracking service")
        try {
            LocationTrackingService.start(context)
        } catch (e: Exception) {
            // Android 12+ only exempts certain background FGS starts. BOOT_COMPLETED is exempt;
            // the inexact restart alarm is not, unless the app is battery-optimisation exempt —
            // which is what the "Disable optimisation" button on the screen is for.
            Log.w(TAG, "could not restart service from $action: ${e.message}")
        }
    }
}
