package com.spacewire.circle360

import android.content.Context
import android.content.SharedPreferences
import java.security.MessageDigest
import java.security.SecureRandom
import android.util.Base64

/**
 * The voice lock's settings, owned by Kotlin.
 *
 * Mirrors [TrackingState], and for the identical reason: [VoiceLockService] outlives the Flutter
 * engine. After the task is swiped away the Dart isolate is gone, but the listener and the lock
 * overlay must keep working — so the phrase the service matches against, and the passcode the
 * overlay checks, cannot live on the Dart side.
 *
 * This is deliberately *not* the `shared_preferences` plugin's own file. That is
 * `FlutterSharedPreferences`, with a `flutter.` key prefix and an encoding that has changed
 * between plugin versions; reading it from Kotlin would be a silent breakage waiting for a
 * `pub upgrade`. Dart writes here through the method channel instead, and this file is the only
 * source of truth.
 */
object SunioState {

    private const val PREFS = "suniomax_state"

    private const val KEY_ENABLED = "voice_lock_enabled"
    private const val KEY_PHRASE = "voice_phrase"
    private const val KEY_UNLOCK_PHRASE = "unlock_phrase"
    private const val KEY_PASSCODE = "passcode"
    private const val KEY_LOCKED = "locked"

    private fun prefs(context: Context): SharedPreferences =
        context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    // ------------------------------------------------------------- the switch

    fun isEnabled(context: Context): Boolean = prefs(context).getBoolean(KEY_ENABLED, false)

    fun setEnabled(context: Context, value: Boolean) {
        prefs(context).edit().putBoolean(KEY_ENABLED, value).apply()
    }

    // ------------------------------------------------------------- the phrases

    fun phrase(context: Context): String = prefs(context).getString(KEY_PHRASE, "").orEmpty()

    fun unlockPhrase(context: Context): String =
        prefs(context).getString(KEY_UNLOCK_PHRASE, "").orEmpty()

    fun setPhrase(context: Context, value: String) {
        prefs(context).edit().putString(KEY_PHRASE, value.trim()).apply()
    }

    fun setUnlockPhrase(context: Context, value: String) {
        prefs(context).edit().putString(KEY_UNLOCK_PHRASE, value.trim()).apply()
    }

    // ------------------------------------------------------------ the passcode

    fun hasPasscode(context: Context): Boolean =
        !prefs(context).getString(KEY_PASSCODE, "").isNullOrEmpty()

    /**
     * Stores a salted SHA-256 of [passcode].
     *
     * Worth being honest about what this buys: four digits is ten thousand possibilities, so
     * anyone holding this string recovers it instantly whatever the hash. What protects it is that
     * this is app-private storage. The hash is here so the passcode is not sitting in plaintext in
     * a backup or a bug report, and so that lengthening it later is a change to one screen rather
     * than to the storage format.
     */
    fun setPasscode(context: Context, passcode: String) {
        val salt = ByteArray(16).also { SecureRandom().nextBytes(it) }
        val encoded = Base64.encodeToString(salt, Base64.NO_WRAP)
        prefs(context).edit()
            .putString(KEY_PASSCODE, "$encoded:${hash(passcode, encoded)}")
            .apply()
    }

    fun verifyPasscode(context: Context, passcode: String): Boolean {
        val stored = prefs(context).getString(KEY_PASSCODE, "").orEmpty()
        val separator = stored.indexOf(':')
        // An unset passcode must not be something an empty guess satisfies.
        if (separator <= 0) return false

        val salt = stored.substring(0, separator)
        val expected = stored.substring(separator + 1)
        return constantTimeEquals(hash(passcode, salt), expected)
    }

    private fun hash(passcode: String, salt: String): String =
        MessageDigest.getInstance("SHA-256")
            .digest("$salt:$passcode".toByteArray())
            .joinToString("") { "%02x".format(it) }

    /** Compares without returning early, so the time taken says nothing about how much matched. */
    private fun constantTimeEquals(a: String, b: String): Boolean {
        if (a.length != b.length) return false
        var difference = 0
        for (i in a.indices) difference = difference or (a[i].code xor b[i].code)
        return difference == 0
    }

    // --------------------------------------------------------------- the lock

    /**
     * Whether the overlay is currently up.
     *
     * Persisted rather than held in memory because the process can be killed while locked — an
     * OEM battery manager, or simply memory pressure — and a lock that quietly disappears when
     * the system reclaims the process is not a lock. [BootReceiver] and the service both read
     * this to put it back.
     */
    fun isLocked(context: Context): Boolean = prefs(context).getBoolean(KEY_LOCKED, false)

    fun setLocked(context: Context, value: Boolean) {
        prefs(context).edit().putBoolean(KEY_LOCKED, value).apply()
    }

    /**
     * Forgets everything about the voice lock.
     *
     * Called on sign-out. The phrase and the passcode are this user's credentials and they live
     * in app storage, not in the account — so without this the next person to sign in on the
     * handset inherits them, and their phone answers to somebody else's voice.
     */
    fun clear(context: Context) {
        prefs(context).edit()
            .remove(KEY_ENABLED)
            .remove(KEY_PHRASE)
            .remove(KEY_UNLOCK_PHRASE)
            .remove(KEY_PASSCODE)
            .remove(KEY_LOCKED)
            .apply()
    }

    /** Everything Dart needs to render the Voice Lock screen, shaped exactly as it reads it. */
    fun snapshot(context: Context): Map<String, Any?> = mapOf(
        "enabled" to isEnabled(context),
        // The phrases go back to Dart because the screen displays them. The passcode never does.
        "phrase" to phrase(context),
        "unlockPhrase" to unlockPhrase(context),
        "hasPasscode" to hasPasscode(context),
        "locked" to isLocked(context),
        "listening" to VoiceLockService.isRunning,
    )
}
