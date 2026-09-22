package com.spacewire.circle360

import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import android.util.Log
import java.util.Locale
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Records a phrase once, and hands back exactly what the recogniser heard.
 *
 * ## Why the phrase is spoken and not typed
 *
 * This is the whole reason the feature works at all. `SpeechRecognizer` has its own idea of what
 * the words are: say "Hare Krishna" and it may transcribe "hairy krishna", "hare krishnaa", or
 * something else again, consistently, on that device, in that language. A phrase the user *typed*
 * would then never match what the service hears, and the lock would simply never fire — with
 * nothing on screen to explain why.
 *
 * Capturing it through the same recogniser that will later match it guarantees the stored string
 * is one that engine actually produces. The user is shown the transcription before it is saved, so
 * a bad capture is visible rather than discovered a week later.
 *
 * ## Why it retries
 *
 * [VoiceLockService] holds the microphone whenever the lock is armed, and stopping it is an
 * `Intent` — asynchronous, so it is still holding it for a moment after the request. Starting a
 * second recogniser in that window fails instantly with `ERROR_RECOGNIZER_BUSY`, which looks
 * exactly like "you said nothing" unless it is handled. So a busy recogniser is waited out rather
 * than reported.
 */
object PhraseCapture {

    private const val TAG = "Loc360"

    /** Nothing said in this long is a failed capture rather than an endless wait. */
    private const val TIMEOUT_MS = 10_000L

    /** How long to let the service let go of the microphone before giving up on it. */
    private const val BUSY_RETRY_MS = 350L
    private const val BUSY_MAX_RETRIES = 6

    private var recognizer: SpeechRecognizer? = null

    /**
     * What happened, in terms the user can act on.
     *
     * Every failure used to collapse to "nothing was heard", which is wrong for most of them and
     * actively misleading for the two most common — a busy recogniser and a missing permission.
     * `reason` is passed through to Dart and shown as-is.
     */
    data class Result(val phrase: String?, val reason: String?) {
        companion object {
            fun heard(phrase: String) = Result(phrase, null)
            fun failed(reason: String) = Result(null, reason)
        }
    }

    fun capture(context: Context, languageTag: String?, onResult: (Result) -> Unit) {
        cancel()
        attempt(context.applicationContext, languageTag, 0, onResult)
    }

    private fun attempt(
        context: Context,
        languageTag: String?,
        retries: Int,
        onResult: (Result) -> Unit,
    ) {
        if (!SpeechRecognizer.isRecognitionAvailable(context)) {
            Log.e(TAG, "no speech recognition available on this device")
            onResult(
                Result.failed(
                    "This phone has no speech recognition available. Install or enable " +
                        "Google's speech services, then try again."
                )
            )
            return
        }

        val handler = Handler(Looper.getMainLooper())
        val answered = AtomicBoolean(false)

        fun answer(result: Result) {
            if (!answered.compareAndSet(false, true)) return
            handler.removeCallbacksAndMessages(null)
            // Never destroyed from inside its own callback — that is documented as undefined and
            // does genuinely wedge the engine on some devices.
            handler.post { cancel() }
            onResult(result)
        }

        /** Waits out a recogniser the service has not released yet. */
        fun retryOrFail(reason: String) {
            if (retries >= BUSY_MAX_RETRIES) {
                answer(Result.failed(reason))
                return
            }
            if (!answered.compareAndSet(false, true)) return
            handler.removeCallbacksAndMessages(null)
            handler.postDelayed({
                cancel()
                attempt(context, languageTag, retries + 1, onResult)
            }, BUSY_RETRY_MS)
        }

        val speech = SpeechRecognizer.createSpeechRecognizer(context)
        recognizer = speech

        // The last non-empty partial.
        //
        // This is what makes capture reliable. The engine regularly detects speech, transcribes
        // it into partials, and then hands back an EMPTY final — the device log reads
        // "#onStartOfSpeech … Size: 0 … NO_SPEECH_DETECTED" for a phrase that was clearly
        // spoken. The partials had the words all along; nothing was asking for them.
        var bestPartial: String? = null

        speech.setRecognitionListener(object : RecognitionListener {
            override fun onResults(results: Bundle?) {
                // The first entry is the recogniser's own best guess, which is the one the
                // service will produce again when it hears the same words.
                val best = results
                    ?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                    ?.firstOrNull()
                    ?.trim()

                // An empty final with a good partial behind it is the common case, not an
                // edge case. Prefer whichever actually has words.
                val resolved = best?.takeIf { it.isNotEmpty() } ?: bestPartial

                if (resolved.isNullOrEmpty()) {
                    retryOrFail(
                        "Nothing was recognised. Speak a little longer and closer to the " +
                            "phone \u2014 a two or three word phrase works better than one word."
                    )
                } else {
                    answer(Result.heard(resolved))
                }
            }

            override fun onError(error: Int) {
                Log.d(TAG, "phrase capture error $error (retry $retries)")

                // NO_SPEECH_DETECTED is reported even when the partials clearly had words, so a
                // partial in hand beats the engine's own verdict.
                bestPartial?.let {
                    answer(Result.heard(it))
                    return
                }

                when (error) {
                    // The service has not let go of the microphone yet. Not a user problem.
                    SpeechRecognizer.ERROR_RECOGNIZER_BUSY ->
                        retryOrFail(
                            "The microphone is busy. Turn Voice Lock off, record your " +
                                "phrase, then turn it back on."
                        )

                    SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS ->
                        answer(
                            Result.failed(
                                "SunioMax does not have microphone access. Allow it in " +
                                    "Settings, then try again."
                            )
                        )

                    SpeechRecognizer.ERROR_NETWORK,
                    SpeechRecognizer.ERROR_NETWORK_TIMEOUT ->
                        answer(
                            Result.failed(
                                "Speech recognition needs a connection on this phone, and it " +
                                    "could not reach the network."
                            )
                        )

                    SpeechRecognizer.ERROR_SERVER ->
                        answer(
                            Result.failed(
                                "The speech service refused the request. Try again in a moment."
                            )
                        )

                    SpeechRecognizer.ERROR_NO_MATCH,
                    SpeechRecognizer.ERROR_SPEECH_TIMEOUT ->
                        answer(
                            Result.failed(
                                "Nothing was heard. Tap the circle and speak clearly, close " +
                                    "to the phone."
                            )
                        )

                    // ERROR_CLIENT is what an engine that is mid-teardown reports, so it is
                    // worth one retry before being believed.
                    SpeechRecognizer.ERROR_CLIENT ->
                        retryOrFail("The speech engine did not start. Try again.")

                    else ->
                        answer(Result.failed("Could not record the phrase (error $error)."))
                }
            }

            override fun onReadyForSpeech(params: Bundle?) {}
            override fun onBeginningOfSpeech() {}
            override fun onRmsChanged(rmsdB: Float) {}
            override fun onBufferReceived(buffer: ByteArray?) {}
            override fun onEndOfSpeech() {}
            override fun onPartialResults(partialResults: Bundle?) {
                partialResults
                    ?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                    ?.firstOrNull()
                    ?.trim()
                    ?.takeIf { it.isNotEmpty() }
                    ?.let { bestPartial = it }
            }
            override fun onEvent(eventType: Int, params: Bundle?) {}
        })

        val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(
                RecognizerIntent.EXTRA_LANGUAGE_MODEL,
                RecognizerIntent.LANGUAGE_MODEL_FREE_FORM,
            )
            // The language the user picked during onboarding, so a Hindi phrase is captured by
            // the Hindi model — and later matched by it too.
            //
            // Only on the first try. A locale whose on-device model is not installed also
            // returns an empty result set rather than an error, so the retry below drops this
            // and lets the engine use whatever it does have.
            if (retries < 1) {
                languageTag?.takeIf { it.isNotBlank() }?.let {
                    putExtra(RecognizerIntent.EXTRA_LANGUAGE, it)
                }
            }
            putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 1)

            // Asked for explicitly. `onPartialResults` is never called without this, which is
            // why the fallback above had nothing to fall back to.
            putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)

            // Without this the Google recogniser accepts the request, runs, and returns an
            // EMPTY result set — the on-device ASR logs "Final recognition has been created.
            // Size: 0" and nothing else. It looks exactly like the user said nothing. It is the
            // single most common reason a working microphone produces no text.
            putExtra(RecognizerIntent.EXTRA_CALLING_PACKAGE, context.packageName)

            // The EXTRA_SPEECH_INPUT_*_MILLIS timing hints are deliberately not set. They are
            // documented as "not guaranteed to be honoured", and on this engine a minimum length
            // longer than the utterance is one of the ways a final result comes back empty.
            // Partial results cover what they were there for.
        }

        try {
            speech.startListening(intent)
            // A recogniser that never calls back at all is a real state on some OEM builds.
            handler.postDelayed(
                { answer(Result.failed("The speech engine did not respond. Try again.")) },
                TIMEOUT_MS,
            )
        } catch (e: Exception) {
            Log.e(TAG, "could not start phrase capture: ${e.message}")
            answer(Result.failed("Could not start the microphone. Try again."))
        }
    }

    fun cancel() {
        runCatching { recognizer?.destroy() }
        recognizer = null
    }
}
