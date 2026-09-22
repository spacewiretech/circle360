package com.spacewire.circle360

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import android.util.Log
import java.util.Locale

/**
 * Listens for the lock and unlock phrases, and puts [LockOverlay] up when it hears the first.
 *
 * ## Why a foreground service
 *
 * The phrase has to work when the app is closed, which means surviving the Flutter engine. This
 * is the same shape as [LocationTrackingService] and for the same reason — but with
 * `foregroundServiceType="microphone"`, which Android 14+ requires for anything that records, and
 * which brings two rules with it that shape everything below:
 *
 *  * it **cannot be started while the app is in the background**, so arming is only ever offered
 *    from the Voice Lock screen; and
 *  * it **cannot be started from `BOOT_COMPLETED`** at all, so after a reboot [BootReceiver] can
 *    only post a notification asking the user to reopen the app. There is no way around that one.
 *
 * ## Why `SpeechRecognizer` restarts in a loop
 *
 * `SpeechRecognizer` is built for one utterance at a time: it ends every attempt with `onResults`
 * or `onError` and then does nothing until asked again. There is no continuous mode. So this
 * restarts it each time, with a short backoff on the errors that mean "nothing was said" and a
 * longer one on the errors that mean the recogniser itself is unhappy — without the backoff a
 * `ERROR_RECOGNIZER_BUSY` loop spins the CPU and empties the battery in an afternoon.
 *
 * That is a real limitation of the platform recogniser rather than of this code. It is the
 * trade that was chosen over bundling an offline wake-word engine, and it means the occasional
 * missed phrase is expected.
 */
class VoiceLockService : Service() {

    companion object {
        private const val TAG = "Loc360"
        private const val CHANNEL_ID = "suniomax_voice_lock"
        private const val NOTIFICATION_ID = 4301

        const val ACTION_START = "com.spacewire.circle360.VOICE_START"
        const val ACTION_STOP = "com.spacewire.circle360.VOICE_STOP"

        /** Broadcast so the Flutter UI live-updates while it happens to be alive. */
        const val BROADCAST_UPDATE = "com.spacewire.circle360.VOICE_LOCK_UPDATE"

        /** Restart delay after a silent attempt — short, because this is the normal case. */
        private const val IDLE_RESTART_MS = 400L

        /** Restart delay after the recogniser complains. Long enough not to spin. */
        private const val ERROR_RESTART_MS = 3_000L

        /**
         * How long after a lock or unlock to ignore what is heard.
         *
         * Long enough to cover the rest of the sentence that caused it, arriving in the next
         * recogniser session; short enough that a user who genuinely wants to lock straight after
         * unlocking only has to pause.
         */
        private const val ACTION_COOLDOWN_MS = 2_000L

        /** Whether the listener is up. Read by [SunioState.snapshot] for the Dart side. */
        @Volatile
        var isRunning: Boolean = false
            private set

        fun start(context: Context) {
            val intent = Intent(context, VoiceLockService::class.java).setAction(ACTION_START)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            context.startService(
                Intent(context, VoiceLockService::class.java).setAction(ACTION_STOP)
            )
        }
    }

    private var recognizer: SpeechRecognizer? = null
    private val handler = Handler(Looper.getMainLooper())
    private var listening = false

    /// A stable token for the re-arm, so cancelling it cannot cancel anything else queued on the
    /// same handler — the overlay, above all.
    private val armRunnable = Runnable { arm() }

    /// Set once this utterance has locked or unlocked, and cleared when the next one begins.
    /// One sentence is one command, however many callbacks carry it.
    private var handledUtterance = false

    /// When the lock last changed, so the tail of the same speech arriving in the next recogniser
    /// session is not read as a second command.
    private var lastActionAt = 0L

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                stopListening()
                return START_NOT_STICKY
            }
            else -> startListening()
        }
        // START_STICKY asks the system to recreate us if we are killed for memory. The user armed
        // this deliberately; it coming back is what they expect.
        return START_STICKY
    }

    private fun startListening() {
        // Android 14+ kills a microphone service that does not promote itself within a few
        // seconds, and the type is mandatory.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                buildNotification(),
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE,
            )
        } else {
            startForeground(NOTIFICATION_ID, buildNotification())
        }

        if (listening) return

        if (!SpeechRecognizer.isRecognitionAvailable(this)) {
            // No recogniser on the device — a Google-app-less ROM, or one where it was disabled.
            // Nothing here can fix that, and pretending to listen would be worse than stopping.
            Log.e(TAG, "no speech recognition available on this device")
            stopListening()
            return
        }

        // A service that has only just started has no overlay up, whatever storage claims. This
        // is what heals a `locked` flag stranded by a process killed mid-lock.
        if (!LockOverlay.isShowing) SunioState.setLocked(this, false)

        listening = true
        isRunning = true
        broadcast()
        arm()
        Log.d(TAG, "voice lock listening")
    }

    /** Creates a recogniser and asks it for one utterance. */
    private fun arm() {
        if (!listening) return

        recognizer?.destroy()
        val speech = SpeechRecognizer.createSpeechRecognizer(this)
        recognizer = speech
        // Must be set before any command, or no callback is ever delivered.
        speech.setRecognitionListener(Listener())

        val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(
                RecognizerIntent.EXTRA_LANGUAGE_MODEL,
                RecognizerIntent.LANGUAGE_MODEL_FREE_FORM,
            )
            // Without this the Google recogniser runs and returns an EMPTY result set — the
            // on-device ASR logs "Final recognition has been created. Size: 0" and the phrase is
            // never matched, with no error to explain it. Same reason as in PhraseCapture.
            putExtra(RecognizerIntent.EXTRA_CALLING_PACKAGE, packageName)

            // The device locale is deliberately NOT pinned here. A locale whose on-device model
            // is missing returns empty results rather than an error, and a listener that
            // silently never matches is the worst failure this feature has. Letting the engine
            // pick what it actually has installed is what keeps it working.
            //
            // EXTRA_PREFER_OFFLINE is likewise absent: forcing offline on a device with no
            // offline model produces the same silent emptiness.
            putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 5)

            // [Listener.onPartialResults] is the main way this matches a phrase at all — a
            // phrase said mid-sentence often produces no final result, and an empty final is
            // common even when one does arrive. Without this extra that callback never fires.
            putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
        }

        // A fresh session is a fresh sentence.
        handledUtterance = false

        try {
            speech.startListening(intent)
        } catch (e: Exception) {
            Log.e(TAG, "could not start listening: ${e.message}")
            restart(ERROR_RESTART_MS)
        }
    }

    /**
     * Re-arms the recogniser after [delay].
     *
     * Cancels **only itself**. It used to call `removeCallbacksAndMessages(null)`, which clears
     * every pending callback on this handler — including the `LockOverlay.show` that [lock] posts
     * one line earlier in [Listener.onResults]:
     *
     *     onHeard(matches)          // -> lock() -> handler.post { show }
     *     restart(IDLE_RESTART_MS)  // -> removed that post before it could run
     *
     * Recogniser callbacks arrive on the main looper, so the posted runnable was still queued and
     * never ran. The phrase matched, the log said so, and the overlay never appeared — every time.
     */
    private fun restart(delay: Long) {
        if (!listening) return
        handler.removeCallbacks(armRunnable)
        handler.postDelayed(armRunnable, delay)
    }

    private fun stopListening() {
        listening = false
        isRunning = false
        handler.removeCallbacksAndMessages(null)
        try {
            recognizer?.destroy()
        } catch (e: Exception) {
            Log.e(TAG, "could not destroy the recognizer: ${e.message}")
        }
        recognizer = null
        broadcast()
        Log.d(TAG, "voice lock stopped")
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    /**
     * Decides what a heard utterance means.
     *
     * **Exactly one of the two phrases is live at any moment**: locked, only the unlock phrase is
     * considered; unlocked, only the lock phrase is. That is the intent, and three separate things
     * are needed to make it true.
     *
     * 1. *Whole words, not substrings.* "unlock my phone" **contains** "lock my phone". With a raw
     *    `contains` the unlock phrase hid the lock phrase inside itself, so unlocking immediately
     *    re-locked. [containsPhrase] matches a contiguous run of whole words instead.
     * 2. *One action per utterance.* Partial results arrive repeatedly for a single utterance and
     *    are then followed by the final. Without [handledUtterance] the same sentence is judged
     *    several times — and the lock state flips between those judgements, so the second look
     *    sees a different world than the first.
     * 3. *A cooldown.* The recogniser restarts every few hundred milliseconds, and the tail of the
     *    same speech lands in the next session. [ACTION_COOLDOWN_MS] is what stops that being
     *    read as a second command.
     */
    private fun onHeard(candidates: List<String>) {
        if (handledUtterance) return
        if (android.os.SystemClock.elapsedRealtime() - lastActionAt < ACTION_COOLDOWN_MS) return

        val phrase = normalise(SunioState.phrase(this))
        val unlock = normalise(SunioState.unlockPhrase(this))
        val heard = candidates.map { normalise(it) }

        // Whether the overlay is up, asked rather than remembered. A local flag drifts out of
        // step the moment anything else shows or hides the lock — a keypad unlock, a process
        // death while locked — and a stale one means the unlock phrase silently stops working.
        val locked = LockOverlay.isShowing || SunioState.isLocked(this)

        if (locked) {
            // Locked: the lock phrase is not listened for at all. Nothing said while the phone is
            // locked can lock it again.
            if (unlock.isNotEmpty() && heard.any { containsPhrase(it, unlock) }) {
                Log.d(TAG, "unlock phrase heard")
                handledUtterance = true
                unlock()
            }
            return
        }

        // Unlocked: only the lock phrase counts.
        if (phrase.isNotEmpty() && heard.any { containsPhrase(it, phrase) }) {
            Log.d(TAG, "lock phrase heard")
            handledUtterance = true
            lock()
        }
    }

    /**
     * Whether [phrase]'s words appear as a contiguous run of whole words inside [heard].
     *
     * Word-wise rather than character-wise, which is the whole point: "lock my phone" must not be
     * found inside "unlock my phone". Still a containment test rather than equality, so "ok, hare
     * krishna please" is understood — the recogniser returns whole sentences and a user should not
     * have to say the phrase in isolation.
     *
     * Both sides are already lowercased and stripped of punctuation by [normalise].
     */
    private fun containsPhrase(heard: String, phrase: String): Boolean {
        val words = heard.split(' ').filter { it.isNotEmpty() }
        val target = phrase.split(' ').filter { it.isNotEmpty() }
        if (target.isEmpty() || target.size > words.size) return false

        for (start in 0..(words.size - target.size)) {
            if (target.indices.all { words[start + it] == target[it] }) return true
        }
        return false
    }

    /**
     * Lowercases and strips punctuation, keeping letters of every script.
     *
     * It used to allowlist `[^a-z0-9\u0900-\u097F ]` — Latin, digits and Devanagari only. The
     * language picker offers nine languages, and that expression **deleted every character of
     * six of them**: Telugu, Tamil, Kannada, Malayalam, Odia and Bangla all normalised to the
     * empty string, so `phrase.isNotEmpty()` was false and the phrase could never match. Only
     * English, Hindi and Marathi worked, and nothing said why.
     *
     * Removing punctuation and symbols instead is script-agnostic: the recogniser capitalises and
     * punctuates what it returns, and that is the only difference worth ironing out. Whitespace
     * is collapsed so "hare  krishna" and "hare krishna" are the same phrase.
     */
    private fun normalise(value: String): String =
        value.lowercase(Locale.getDefault())
            .replace(Regex("[\\p{P}\\p{S}]"), "")
            .replace(Regex("\\s+"), " ")
            .trim()

    /**
     * Puts the overlay up — unless there is no way back out.
     *
     * The one guard that cannot be moved. A phrase can be recorded before a passcode is set, and
     * the switch no longer requires either, so this is the last point at which a phone can be
     * locked with nothing that would open it again. Refusing here costs a user one confusing
     * non-event; not refusing costs them their phone.
     */
    private fun lock() {
        lastActionAt = android.os.SystemClock.elapsedRealtime()
        if (!SunioState.hasPasscode(this)) {
            Log.w(TAG, "lock phrase heard but no backup passcode is set — refusing to lock")
            return
        }
        handler.post {
            // The callback fires when the keypad unlocks it; the overlay has already taken
            // itself down and cleared SunioState by then, so this only has to tell the UI.
            LockOverlay.show(applicationContext) { broadcast() }
            broadcast()
        }
    }

    private fun unlock() {
        lastActionAt = android.os.SystemClock.elapsedRealtime()
        handler.post {
            LockOverlay.hide(applicationContext)
            broadcast()
        }
    }

    /** Tells the Flutter UI, if it is alive, that something changed. */
    private fun broadcast() {
        sendBroadcast(Intent(BROADCAST_UPDATE).setPackage(packageName))
    }

    private inner class Listener : RecognitionListener {
        override fun onResults(results: android.os.Bundle?) {
            val matches = results
                ?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                .orEmpty()
            onHeard(matches)
            restart(IDLE_RESTART_MS)
        }

        /**
         * Partial results matter here. A phrase spoken mid-sentence often never produces a final
         * result — the recogniser keeps waiting for the utterance to end — so acting only on
         * `onResults` misses phrases a user definitely said.
         */
        override fun onPartialResults(partialResults: android.os.Bundle?) {
            val matches = partialResults
                ?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                .orEmpty()
            if (matches.isNotEmpty()) onHeard(matches)
        }

        override fun onError(error: Int) {
            // Silence and timeouts are the normal case, not a problem: most restarts land here.
            val quiet = error == SpeechRecognizer.ERROR_NO_MATCH ||
                error == SpeechRecognizer.ERROR_SPEECH_TIMEOUT
            if (!quiet) Log.d(TAG, "recognizer error $error")
            restart(if (quiet) IDLE_RESTART_MS else ERROR_RESTART_MS)
        }

        override fun onReadyForSpeech(params: android.os.Bundle?) {}
        override fun onBeginningOfSpeech() {}
        override fun onRmsChanged(rmsdB: Float) {}
        override fun onBufferReceived(buffer: ByteArray?) {}
        override fun onEndOfSpeech() {}
        override fun onEvent(eventType: Int, params: android.os.Bundle?) {}
    }

    /**
     * Stock Android keeps a foreground service alive through a swipe-away, but Xiaomi/Oppo/Vivo/
     * Huawei ROMs tear the whole process down. The same restart alarm the location tracker uses.
     */
    override fun onTaskRemoved(rootIntent: Intent?) {
        if (SunioState.isEnabled(this)) {
            val restart = PendingIntent.getBroadcast(
                this,
                1,
                Intent(this, BootReceiver::class.java).setAction(BootReceiver.ACTION_RESTART_VOICE),
                PendingIntent.FLAG_ONE_SHOT or PendingIntent.FLAG_IMMUTABLE,
            )
            val alarms = getSystemService(Context.ALARM_SERVICE) as android.app.AlarmManager
            alarms.set(
                android.app.AlarmManager.ELAPSED_REALTIME_WAKEUP,
                android.os.SystemClock.elapsedRealtime() + 1_000L,
                restart,
            )
        }
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        listening = false
        isRunning = false
        handler.removeCallbacksAndMessages(null)
        runCatching { recognizer?.destroy() }
        recognizer = null
        super.onDestroy()
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            getString(R.string.voice_lock_channel),
            NotificationManager.IMPORTANCE_LOW, // no sound, still always visible
        ).apply {
            description = getString(R.string.voice_lock_notification_text)
            setShowBadge(false)
        }
        (getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager)
            .createNotificationChannel(channel)
    }

    private fun buildNotification(): Notification {
        val openApp = PendingIntent.getActivity(
            this,
            1,
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
            .setContentTitle(getString(R.string.voice_lock_notification_title))
            .setContentText(getString(R.string.voice_lock_notification_text))
            .setSmallIcon(android.R.drawable.ic_lock_lock)
            .setContentIntent(openApp)
            .setOngoing(true)
            .build()
    }
}
