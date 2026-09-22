package com.spacewire.circle360

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.PixelFormat
import android.os.Build
import android.provider.Settings
import android.util.Log
import android.view.Gravity
import android.view.KeyEvent
import android.view.LayoutInflater
import android.view.View
import android.view.WindowManager
import android.widget.TextView
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * The lock screen, drawn over everything.
 *
 * ## Why a window and not an Activity
 *
 * An Activity can be dismissed. Pressing Home moves it to the back and the launcher takes the
 * foreground — which is exactly the thing this must not allow. A `TYPE_APPLICATION_OVERLAY`
 * window is not in the activity stack at all: Home shows the launcher *underneath* it and the
 * overlay stays on top, which is the whole reason for the `SYSTEM_ALERT_WINDOW` permission.
 *
 * Android 10+ also forbids launching an Activity from the background, so a service that hears the
 * phrase while another app is in the foreground could not start one anyway.
 *
 * ## What this genuinely does and does not block
 *
 * Covered: Home, Recents, switching apps, the launcher, and Back — the window takes focus so it
 * receives `KEYCODE_BACK` and swallows it.
 *
 * **Not covered: the notification shade and the quick settings panel.** Those are system windows
 * and they draw above every application overlay; there is no API that stops them, and the only
 * thing that ever could was an `AccessibilityService`, which Google Play does not permit for
 * screen-lock apps. A determined user can pull the shade down over this. That is a deliberate,
 * accepted limit of the overlay approach — not a bug to be fixed with a hack.
 */
object LockOverlay {

    private const val TAG = "Loc360"

    private var view: View? = null
    private var windowManager: WindowManager? = null

    /** Held so [hide] can stop the clock. Without this the controller's one-second `postDelayed`
     *  loop keeps running against a detached view for the life of the process. */
    private var controller: LockScreenController? = null

    /** Whether the overlay is currently on screen. */
    val isShowing: Boolean get() = view != null

    /** Whether the user has granted "Display over other apps". */
    fun canDraw(context: Context): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.M || Settings.canDrawOverlays(context)

    @SuppressLint("InflateParams")
    fun show(context: Context, onUnlocked: () -> Unit) {
        if (view != null) return
        if (!canDraw(context)) {
            // Nothing to be done about it here: the grant is a Settings screen, and a service
            // cannot ask. The switch is refused in the first place without it — see MainActivity.
            Log.w(TAG, "cannot show the lock overlay: no SYSTEM_ALERT_WINDOW grant")
            return
        }

        val app = context.applicationContext
        val manager = app.getSystemService(Context.WINDOW_SERVICE) as WindowManager
        val inflated = LayoutInflater.from(app).inflate(R.layout.lock_screen, null)

        val params = WindowManager.LayoutParams(
            WindowManager.LayoutParams.MATCH_PARENT,
            WindowManager.LayoutParams.MATCH_PARENT,
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
            } else {
                @Suppress("DEPRECATION")
                WindowManager.LayoutParams.TYPE_SYSTEM_ERROR
            },
            // FLAG_NOT_FOCUSABLE is deliberately absent: without focus the window never receives
            // key events, and Back would fall through to whatever is underneath.
            //
            // The other three put it over the status and navigation bars rather than inside the
            // content area, so there is no strip of the app beneath showing around the edges.
            WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON or
                WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN or
                WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
            PixelFormat.OPAQUE,
        ).apply { gravity = Gravity.TOP or Gravity.START }

        val screen = LockScreenController(
            app = app,
            root = inflated,
            onUnlocked = {
                hide(app)
                onUnlocked()
            },
        )
        screen.bind()

        inflated.isFocusableInTouchMode = true
        inflated.requestFocus()
        inflated.setOnKeyListener { _, keyCode, _ ->
            // Back is swallowed rather than handled: returning true says the event is dealt with,
            // so nothing underneath ever sees it. Both DOWN and UP are consumed — letting either
            // through is enough for the app below to act on it.
            keyCode == KeyEvent.KEYCODE_BACK
        }

        try {
            manager.addView(inflated, params)
            view = inflated
            windowManager = manager
            controller = screen
            SunioState.setLocked(app, true)
            Log.d(TAG, "lock overlay shown")
        } catch (e: Exception) {
            // A revoked grant, or an OEM that refuses the window type outright.
            Log.e(TAG, "could not add the lock overlay: ${e.message}")
            screen.dispose()
        }
    }

    fun hide(context: Context) {
        // Cleared FIRST, before the early return below.
        //
        // The flag is persisted so a lock survives the process being killed. But if the process
        // died while locked, the window is gone and `view` is null on the next launch — so an
        // early return here left `locked = true` in storage with nothing able to clear it. The
        // service then reads that flag, believes it is already locked, and never fires the lock
        // phrase again. Permanently: the unlock phrase, the off switch and a re-arm all route
        // through this same function.
        SunioState.setLocked(context.applicationContext, false)

        val current = view ?: return
        try {
            windowManager?.removeView(current)
        } catch (e: Exception) {
            Log.e(TAG, "could not remove the lock overlay: ${e.message}")
        }
        controller?.dispose()
        controller = null
        view = null
        windowManager = null
        Log.d(TAG, "lock overlay hidden")
    }
}

/**
 * The behaviour inside the lock window: the clock, the two faces, and the keypad.
 *
 * Separated from [LockOverlay] so the window plumbing and the screen's logic are not one file, and
 * so the keypad can be reasoned about on its own — it is the part that decides whether the phone
 * opens.
 */
private class LockScreenController(
    private val app: Context,
    private val root: View,
    private val onUnlocked: () -> Unit,
) {
    private val clock: TextView = root.findViewById(R.id.lock_clock)
    private val date: TextView = root.findViewById(R.id.lock_date)
    private val voiceFace: View = root.findViewById(R.id.lock_voice_face)
    private val passcodeFace: View = root.findViewById(R.id.lock_passcode_face)
    private val passcodeError: TextView = root.findViewById(R.id.lock_passcode_error)
    private val dots = listOf<View>(
        root.findViewById(R.id.lock_dot_1),
        root.findViewById(R.id.lock_dot_2),
        root.findViewById(R.id.lock_dot_3),
        root.findViewById(R.id.lock_dot_4),
    )

    private val entered = StringBuilder()
    private var ticking = true

    fun bind() {
        tick()
        root.findViewById<View>(R.id.lock_show_passcode).setOnClickListener { showPasscode(true) }
        root.findViewById<View>(R.id.lock_cancel).setOnClickListener { showPasscode(false) }

        val keys = mapOf(
            R.id.key_0 to "0", R.id.key_1 to "1", R.id.key_2 to "2", R.id.key_3 to "3",
            R.id.key_4 to "4", R.id.key_5 to "5", R.id.key_6 to "6", R.id.key_7 to "7",
            R.id.key_8 to "8", R.id.key_9 to "9",
        )
        keys.forEach { (id, digit) ->
            root.findViewById<View>(id).setOnClickListener { press(digit) }
        }
        root.findViewById<View>(R.id.key_delete).setOnClickListener { backspace() }

        showPasscode(false)
        render()
    }

    fun dispose() {
        ticking = false
    }

    /** Redraws the clock every second for as long as the window is up. */
    private fun tick() {
        if (!ticking) return
        val now = Date()
        clock.text = SimpleDateFormat("HH:mm", Locale.getDefault()).format(now)
        date.text = SimpleDateFormat("EEE, MMM d", Locale.getDefault()).format(now)
        root.postDelayed({ tick() }, 1_000)
    }

    private fun showPasscode(show: Boolean) {
        voiceFace.visibility = if (show) View.GONE else View.VISIBLE
        passcodeFace.visibility = if (show) View.VISIBLE else View.GONE
        entered.clear()
        passcodeError.visibility = View.GONE
        render()
    }

    private fun press(digit: String) {
        if (entered.length >= 4) return
        entered.append(digit)
        passcodeError.visibility = View.GONE
        render()
        if (entered.length == 4) root.postDelayed({ submit() }, 120)
    }

    private fun backspace() {
        if (entered.isNotEmpty()) entered.deleteCharAt(entered.length - 1)
        render()
    }

    private fun submit() {
        if (SunioState.verifyPasscode(app, entered.toString())) {
            onUnlocked()
            return
        }
        // Cleared rather than left on screen, so a wrong code does not have to be deleted by hand.
        entered.clear()
        passcodeError.visibility = View.VISIBLE
        render()
    }

    private fun render() {
        dots.forEachIndexed { index, dot ->
            dot.setBackgroundResource(
                if (index < entered.length) R.drawable.lock_dot_filled else R.drawable.lock_dot_empty
            )
        }
    }
}
