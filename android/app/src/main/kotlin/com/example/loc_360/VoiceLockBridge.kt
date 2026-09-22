package com.spacewire.circle360

import android.Manifest
import android.app.Activity
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import android.util.Log
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * The voice lock's Flutter bridge.
 *
 * Its own file rather than more branches inside [MainActivity], which is already the location
 * tracker's bridge and has nothing to do with this. The two features share an activity and
 * nothing else.
 *
 * ## Where the boundary is
 *
 * Dart owns the screens and the decisions; Kotlin owns the state, because [VoiceLockService] and
 * [LockOverlay] outlive the Flutter engine and cannot ask Dart anything once it is gone. So every
 * setter here writes [SunioState] and the answer comes back from there — Dart never holds the
 * authoritative copy.
 *
 * The passcode is the one value that only travels one way. It goes in, and only ever a boolean
 * comes back.
 */
class VoiceLockBridge(private val activity: Activity) {

    companion object {
        private const val TAG = "Loc360"
        const val METHOD_CHANNEL = "suniomax/voicelock"
        const val EVENT_CHANNEL = "suniomax/voicelock_events"

        private const val REQ_MICROPHONE = 2001
        private const val REQ_NOTIFICATIONS = 2002

        /** How long to let [VoiceLockService] release the microphone before recording. */
        private const val SERVICE_RELEASE_MS = 450L
    }

    private var eventSink: EventChannel.EventSink? = null
    private var updateReceiver: BroadcastReceiver? = null
    private var pendingPermissionResult: MethodChannel.Result? = null

    fun methodHandler(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "getState" -> {
                // Starting the service is an Intent, so `isRunning` is still false in the reply
                // below. Saying so would raise the "on but not listening" alarm on every single
                // app open; the flag tells Dart to wait for the event channel instead.
                val rearming = rearmIfNeeded()
                result.success(state() + mapOf("rearming" to rearming))
            }

            "setEnabled" -> {
                val enabled = call.argument<Boolean>("enabled") ?: false
                result.success(setEnabled(enabled))
            }

            "setPhrase" -> {
                SunioState.setPhrase(activity, call.argument<String>("phrase").orEmpty())
                result.success(state())
            }

            "setUnlockPhrase" -> {
                SunioState.setUnlockPhrase(activity, call.argument<String>("phrase").orEmpty())
                result.success(state())
            }

            "setPasscode" -> {
                SunioState.setPasscode(activity, call.argument<String>("passcode").orEmpty())
                result.success(state())
            }

            // The only thing that ever comes back about the passcode.
            "verifyPasscode" -> result.success(
                SunioState.verifyPasscode(activity, call.argument<String>("passcode").orEmpty())
            )

            "permissions" -> result.success(permissions())

            "requestMicrophone" -> {
                pendingPermissionResult = result
                requestMicrophone()
            }

            "requestNotifications" -> {
                pendingPermissionResult = result
                requestNotifications()
            }

            // Both of these are Settings screens rather than dialogs — there is no runtime
            // request for either — so the answer is whatever is true when the user comes back,
            // which Dart re-reads on resume.
            "requestOverlay" -> {
                openOverlaySettings()
                result.success(permissions())
            }

            "requestIgnoreBatteryOptimizations" -> {
                requestIgnoreBatteryOptimizations()
                result.success(permissions())
            }

            // Sign-out. Stops the listener, takes any overlay down, and forgets the phrases
            // and the passcode — they belong to the user who is leaving.
            "clear" -> {
                VoiceLockService.stop(activity)
                LockOverlay.hide(activity.applicationContext)
                SunioState.clear(activity)
                result.success(state())
            }

            // Records a phrase once and hands back what the recogniser heard. See PhraseCapture
            // for why the phrase is spoken rather than typed.
            "capturePhrase" -> capturePhrase(call.argument<String>("language"), result)

            else -> result.notImplemented()
        }
    }

    /**
     * Restarts the listener when the user left it on but nothing is running.
     *
     * **Without this the feature silently stops working after the app is closed.** The service is
     * only ever started from [setEnabled], so a process killed for memory, force-stopped, or
     * simply reopened the next day comes back with `voice_lock_enabled = true` in storage and
     * nothing listening — the user says their phrase and the phone does not lock, with no
     * indication anything is wrong.
     *
     * It has to happen here, on a method call from the foreground, and not from a broadcast:
     * Android 14+ refuses to start a `microphone` foreground service from the background or from
     * `BOOT_COMPLETED`, and there is no exemption to apply for. Opening the app is the only
     * moment this is allowed to happen, which is why it hangs off `getState`.
     */
    private fun rearmIfNeeded(): Boolean {
        if (VoiceLockService.isRunning) return false
        if (!SunioState.isEnabled(activity)) return false

        // A permission revoked in Settings while the app was away. Record what is true rather
        // than starting a service that cannot work.
        if (!hasMicrophone() || !LockOverlay.canDraw(activity)) {
            Log.d(TAG, "voice lock was on but its permissions are gone — turning it off")
            SunioState.setEnabled(activity, false)
            return false
        }

        Log.d(TAG, "voice lock was on but not running — re-arming")
        VoiceLockService.start(activity)
        return true
    }

    // ------------------------------------------------------------ phrase capture

    /**
     * Stops the listener, records one phrase, and puts the listener back.
     *
     * The stop is not optional: [VoiceLockService] holds the microphone for as long as it is
     * armed, and two `SpeechRecognizer` instances cannot have it at once — without this, changing
     * a phrase while the lock is on fails with `ERROR_RECOGNIZER_BUSY` every time.
     */
    private fun capturePhrase(language: String?, result: MethodChannel.Result) {
        if (!hasMicrophone()) {
            // Capture is usually the first thing that needs the microphone, so this is where the
            // grant is asked for rather than at the switch.
            result.success(
                mapOf(
                    "granted" to false,
                    "phrase" to null,
                    "reason" to "SunioMax needs the microphone to record your phrase.",
                )
            )
            return
        }

        val wasListening = VoiceLockService.isRunning
        if (wasListening) VoiceLockService.stop(activity)

        // Stopping the service is an Intent, so it is still holding the microphone for a moment
        // after this returns. Starting the capture immediately fails with ERROR_RECOGNIZER_BUSY,
        // which reads to the user as "nothing was heard" — the settle wait, plus PhraseCapture's
        // own retry on busy, is what closes that window.
        val settle = if (wasListening) SERVICE_RELEASE_MS else 0L

        android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({
            PhraseCapture.capture(activity, language) { captured ->
                // Re-armed only if it was armed before, so recording a phrase never turns the
                // lock on by itself.
                if (wasListening && SunioState.isEnabled(activity)) {
                    VoiceLockService.start(activity)
                }
                result.success(
                    mapOf(
                        "granted" to true,
                        "phrase" to captured.phrase,
                        "reason" to captured.reason,
                    )
                )
            }
        }, settle)
    }

    // --------------------------------------------------------------- the switch

    /**
     * Arms or disarms the listener.
     *
     * **Permissions are the only thing that can refuse this**, deliberately. The switch comes
     * first in the flow: the user turns the lock on, grants the microphone and the overlay, and
     * only then records a phrase and sets a passcode — so requiring the configuration here would
     * make the switch impossible to turn on and the setup rows impossible to reach.
     *
     * Arming with no phrase yet is harmless: [VoiceLockService] matches nothing against an empty
     * phrase, so the service simply listens and never fires until one is recorded.
     *
     * What stops a lock-out is not here but in [VoiceLockService.lock], which refuses to put the
     * overlay up until a backup passcode exists. That guard sits at the moment of locking rather
     * than at the switch, so it costs the setup flow nothing.
     */
    private fun setEnabled(enabled: Boolean): Map<String, Any?> {
        if (!enabled) {
            SunioState.setEnabled(activity, false)
            VoiceLockService.stop(activity)
            LockOverlay.hide(activity.applicationContext)
            return state()
        }

        if (!hasMicrophone() || !LockOverlay.canDraw(activity)) {
            Log.d(TAG, "refusing to arm the voice lock: microphone or overlay not granted")
            SunioState.setEnabled(activity, false)
            return state()
        }

        SunioState.setEnabled(activity, true)
        // Started from here, which is always the foreground: Android 14+ forbids starting a
        // microphone service from the background.
        VoiceLockService.start(activity)
        return state()
    }

    // ------------------------------------------------------------- permissions

    private fun hasMicrophone() = ContextCompat.checkSelfPermission(
        activity,
        Manifest.permission.RECORD_AUDIO,
    ) == PackageManager.PERMISSION_GRANTED

    private fun hasNotifications(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return true
        return ContextCompat.checkSelfPermission(
            activity,
            Manifest.permission.POST_NOTIFICATIONS,
        ) == PackageManager.PERMISSION_GRANTED
    }

    private fun isBatteryOptimised(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return false
        val pm = activity.getSystemService(Context.POWER_SERVICE) as PowerManager
        return !pm.isIgnoringBatteryOptimizations(activity.packageName)
    }

    private fun permissions(): Map<String, Any?> = mapOf(
        "microphone" to hasMicrophone(),
        "overlay" to LockOverlay.canDraw(activity),
        "notifications" to hasNotifications(),
        "batteryOptimized" to isBatteryOptimised(),
    )

    private fun requestMicrophone() {
        if (hasMicrophone()) {
            resolvePending()
            return
        }
        ActivityCompat.requestPermissions(
            activity,
            arrayOf(Manifest.permission.RECORD_AUDIO),
            REQ_MICROPHONE,
        )
    }

    private fun requestNotifications() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU || hasNotifications()) {
            resolvePending()
            return
        }
        ActivityCompat.requestPermissions(
            activity,
            arrayOf(Manifest.permission.POST_NOTIFICATIONS),
            REQ_NOTIFICATIONS,
        )
    }

    /** "Display over other apps" is a Settings screen; there is no runtime dialog for it. */
    private fun openOverlaySettings() {
        if (LockOverlay.canDraw(activity)) return
        try {
            activity.startActivity(
                Intent(
                    Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                    Uri.parse("package:${activity.packageName}"),
                )
            )
        } catch (e: Exception) {
            // Some OEM ROMs ship without the per-app screen; the app settings page is the fallback.
            Log.d(TAG, "no overlay settings screen: ${e.message}")
            activity.startActivity(
                Intent(
                    Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                    Uri.fromParts("package", activity.packageName, null),
                )
            )
        }
    }

    @Suppress("BatteryLife") // Listening continuously is the feature the user switched on.
    private fun requestIgnoreBatteryOptimizations() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M || !isBatteryOptimised()) return
        try {
            activity.startActivity(
                Intent(
                    Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                    Uri.parse("package:${activity.packageName}"),
                )
            )
        } catch (e: Exception) {
            activity.startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
        }
    }

    /** Called by [MainActivity] for the two request codes this owns. */
    fun onRequestPermissionsResult(requestCode: Int): Boolean {
        if (requestCode != REQ_MICROPHONE && requestCode != REQ_NOTIFICATIONS) return false
        resolvePending()
        return true
    }

    private fun resolvePending() {
        pendingPermissionResult?.success(permissions())
        pendingPermissionResult = null
    }

    // ------------------------------------------------------------------ events

    private fun state(): Map<String, Any?> =
        SunioState.snapshot(activity) + mapOf("permissions" to permissions())

    private fun broadcast() {
        eventSink?.success(state())
    }

    fun streamHandler() = object : EventChannel.StreamHandler {
        override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
            eventSink = events
            registerUpdateReceiver()
            // Seed the stream, so a listener that attaches after the service started still knows.
            events?.success(state())
        }

        override fun onCancel(arguments: Any?) {
            unregisterUpdateReceiver()
            eventSink = null
        }
    }

    private fun registerUpdateReceiver() {
        if (updateReceiver != null) return
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) = broadcast()
        }
        updateReceiver = receiver
        ContextCompat.registerReceiver(
            activity,
            receiver,
            IntentFilter(VoiceLockService.BROADCAST_UPDATE),
            ContextCompat.RECEIVER_NOT_EXPORTED,
        )
    }

    private fun unregisterUpdateReceiver() {
        updateReceiver?.let { runCatching { activity.unregisterReceiver(it) } }
        updateReceiver = null
    }

    fun dispose() {
        unregisterUpdateReceiver()
        eventSink = null
        pendingPermissionResult = null
    }
}
