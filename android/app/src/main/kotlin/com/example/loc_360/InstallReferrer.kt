package com.spacewire.circle360

import android.content.Context
import android.util.Log
import com.android.installreferrer.api.InstallReferrerClient
import com.android.installreferrer.api.InstallReferrerStateListener
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Reads the Play Store install referrer — the `?referrer=utm_source%3D…` payload attached to the
 * store link a paid campaign sends people to.
 *
 * This is the whole of the SunioMax gate. Which app a device runs is decided by what comes back
 * here, so the one thing this must never do is answer wrongly: every failure path returns null,
 * and null means "no answer", not "organic". Dart draws the distinction — an unanswered fetch is
 * retried on the next launch rather than being frozen into a verdict.
 *
 * Play keeps the referrer for the life of the install, so there is no rush and no window to miss.
 * An organic install is not an absent referrer — it comes back as
 * `utm_source=google-play&utm_medium=organic`, which is a real answer and is stored as one.
 *
 * Deliberately not a Flutter plugin: this is forty lines against the same MethodChannel idiom
 * [MainActivity] already uses twice, and the one maintained pub package for it is a fork of an
 * abandoned one.
 */
object InstallReferrer {

    private const val TAG = "Loc360"

    /**
     * Fetches the referrer, calling [onResult] exactly once on the main thread.
     *
     * The guard matters: [InstallReferrerStateListener] has two callbacks and a flaky Play
     * Services can fire both, which would resolve the Dart side's `Result` twice and crash the
     * engine with "Reply already submitted".
     */
    fun fetch(context: Context, onResult: (String?) -> Unit) {
        val answered = AtomicBoolean(false)
        fun answer(referrer: String?) {
            if (answered.compareAndSet(false, true)) onResult(referrer)
        }

        val client = try {
            InstallReferrerClient.newBuilder(context).build()
        } catch (e: Throwable) {
            // No Play Store on the device, or a build that stripped the library.
            Log.d(TAG, "install referrer unavailable: ${e.message}")
            answer(null)
            return
        }

        try {
            client.startConnection(object : InstallReferrerStateListener {
                override fun onInstallReferrerSetupFinished(responseCode: Int) {
                    val referrer = if (responseCode == InstallReferrerClient.InstallReferrerResponse.OK) {
                        // Throws RemoteException if the service died between the callback and here.
                        runCatching { client.installReferrer.installReferrer }.getOrNull()
                    } else {
                        // FEATURE_NOT_SUPPORTED, SERVICE_UNAVAILABLE, SERVICE_DISCONNECTED,
                        // DEVELOPER_ERROR — all "no answer", none of them "organic".
                        Log.d(TAG, "install referrer response $responseCode")
                        null
                    }
                    answer(referrer)
                    runCatching { client.endConnection() }
                }

                override fun onInstallReferrerServiceDisconnected() {
                    answer(null)
                }
            })
        } catch (e: Throwable) {
            Log.d(TAG, "install referrer connection failed: ${e.message}")
            answer(null)
            runCatching { client.endConnection() }
        }
    }
}
