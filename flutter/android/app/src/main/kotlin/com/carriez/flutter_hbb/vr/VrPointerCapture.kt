package com.carriez.flutter_hbb.vr

import android.app.Activity
import android.content.Context
import android.os.Build
import android.util.Log
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import androidx.annotation.RequiresApi
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel

/**
 * Captured Bluetooth-mouse input, forwarded to Dart as relative deltas and button
 * transitions.
 *
 * Pointer capture is what makes a mouse usable in a headset: it yields unbounded
 * relative motion and stops Android drawing its own pointer, which would
 * otherwise appear once between the two eye images and clamp at the panel edges
 * while the remote desktop is larger than the phone's screen.
 *
 * Two details here were each worth a debugging session on real hardware, and
 * neither produces an error of any kind when wrong -- the mouse simply does
 * nothing in VR while working perfectly everywhere else. Both are load-bearing;
 * see [CapturePad] and [deltaOf].
 */
class VrPointerCapture(private val activity: Activity, messenger: BinaryMessenger) {
    companion object {
        private const val LOG_TAG = "VrPointerCapture"
        const val CHANNEL = "rustdesk/vr_mouse"

        /** How many captured events to dump in full on each capture. */
        private const val DUMP_COUNT = 5

        val supported: Boolean get() = Build.VERSION.SDK_INT >= Build.VERSION_CODES.O
    }

    private var sink: EventChannel.EventSink? = null
    private var capturing = false
    private var pad: CapturePad? = null
    private var dumped = 0

    /**
     * Buttons are tracked by diffing [MotionEvent.getButtonState] rather than by
     * listening for ACTION_BUTTON_PRESS/RELEASE. Some mice and some Android
     * builds only ever report plain ACTION_DOWN/UP for the primary button, so
     * diffing the mask is the one approach that catches every device without
     * special-casing any of them.
     */
    private var buttons = 0

    /** Set from Dart while tuning an unfamiliar mouse. */
    var verbose = false

    /**
     * A 1x1 focusable view whose only job is to be the focused view.
     *
     * Captured events are delivered by ViewRootImpl to the FOCUSED view, through
     * View.dispatchCapturedPointerEvent. There is no Activity-level hook for this
     * -- dispatchCapturedPointerEvent is a View method, and overriding it on the
     * Activity does not even compile. So attaching an OnCapturedPointerListener to
     * the FlutterView only works when FlutterView happens to hold focus: true on
     * Android 17, false on an Android 10 Pixel, where capture was granted and not
     * one event was ever delivered.
     *
     * Owning the focused view removes the guesswork. 1x1 so it can never intercept
     * a touch, and present only while capture is held so it cannot strand
     * Flutter's own focus or text input once VR is over.
     */
    @RequiresApi(Build.VERSION_CODES.O)
    private inner class CapturePad(context: Context) : View(context) {
        init {
            isFocusable = true
            isFocusableInTouchMode = true
        }

        override fun onCapturedPointerEvent(event: MotionEvent): Boolean =
            handle(event)

        /** The only authoritative answer to "did this view actually get capture". */
        override fun onPointerCaptureChange(hasCapture: Boolean) {
            super.onPointerCaptureChange(hasCapture)
            Log.i(LOG_TAG, "capture -> $hasCapture")
            emit(mapOf("event" to "capture", "active" to hasCapture))
        }
    }

    private val channel = EventChannel(messenger, CHANNEL).apply {
        setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                sink = events
            }

            override fun onCancel(arguments: Any?) {
                sink = null
            }
        })
    }

    fun capture(): Boolean {
        if (!supported) {
            Log.w(LOG_TAG, "needs API 26+, running on ${Build.VERSION.SDK_INT}")
            return false
        }
        val content = activity.findViewById<ViewGroup>(android.R.id.content) ?: return false
        buttons = 0
        dumped = 0
        capturing = true

        val view = pad ?: CapturePad(activity).also {
            content.addView(it, FrameLayout.LayoutParams(1, 1))
            pad = it
        }
        // Posted, not inline: requestFocus() fails on a view that has been added
        // but not yet laid out, and a pad that never takes focus never receives a
        // captured event either.
        view.post {
            val focused = view.requestFocus()
            view.requestPointerCapture()
            Log.i(LOG_TAG, "requested capture, focus=$focused isFocused=${view.isFocused}")
        }
        return true
    }

    fun release() {
        if (!capturing) return
        capturing = false

        // Release anything we still believe is held, so leaving VR mid-click
        // cannot strand the remote machine with a button down.
        for (bit in BUTTON_BITS) {
            if (buttons and bit != 0) emit(mapOf("event" to "up", "button" to bit))
        }
        buttons = 0

        val view = pad ?: return
        pad = null
        if (!supported) return
        view.post {
            view.releasePointerCapture()
            // Out of the hierarchy entirely: a leftover focusable view would hold
            // focus away from Flutter and break text entry everywhere else.
            (view.parent as? ViewGroup)?.removeView(view)
        }
        Log.i(LOG_TAG, "released capture")
    }

    @RequiresApi(Build.VERSION_CODES.O)
    private fun handle(event: MotionEvent): Boolean {
        if (!capturing) return false

        if (dumped < DUMP_COUNT || verbose) {
            dumped++
            Log.i(
                LOG_TAG,
                "captured[$dumped] source=${event.source} action=${event.actionMasked} " +
                    "buttons=${event.buttonState} " +
                    "relX=${event.getAxisValue(MotionEvent.AXIS_RELATIVE_X)} " +
                    "relY=${event.getAxisValue(MotionEvent.AXIS_RELATIVE_Y)} " +
                    "x=${event.x} y=${event.y}"
            )
        }

        emitButtonChanges(event.buttonState)

        when (event.actionMasked) {
            MotionEvent.ACTION_MOVE, MotionEvent.ACTION_HOVER_MOVE -> {
                val (dx, dy) = deltaOf(event)
                if (dx != 0f || dy != 0f) {
                    emit(mapOf("event" to "move", "dx" to dx.toDouble(), "dy" to dy.toDouble()))
                }
            }

            MotionEvent.ACTION_SCROLL -> {
                // Vertical only. InputModel.scroll takes a y component and has no
                // horizontal path, so forwarding HSCROLL through it would turn a
                // tilt-wheel nudge into bogus vertical scrolling.
                val v = event.getAxisValue(MotionEvent.AXIS_VSCROLL)
                if (v != 0f) emit(mapOf("event" to "scroll", "v" to v.toDouble()))
            }
        }
        return true
    }

    /**
     * Where the relative movement actually is.
     *
     * Under capture the source becomes SOURCE_MOUSE_RELATIVE (131076 = 0x20004),
     * but which field carries the delta varies by device. Measured on an Android
     * 10 Pixel, AXIS_RELATIVE_X/Y are *always zero* and the movement is in
     * getX()/getY(); on others it is the other way round. Reading only the
     * relative axes meant every delta computed as zero, so captured events
     * streamed into Kotlin and nothing was ever emitted -- with no error anywhere.
     */
    @RequiresApi(Build.VERSION_CODES.O)
    private fun deltaOf(event: MotionEvent): Pair<Float, Float> {
        val rx = event.getAxisValue(MotionEvent.AXIS_RELATIVE_X)
        val ry = event.getAxisValue(MotionEvent.AXIS_RELATIVE_Y)
        return if (rx != 0f || ry != 0f) Pair(rx, ry) else Pair(event.x, event.y)
    }

    private fun emitButtonChanges(state: Int) {
        if (state == buttons) return
        val changed = state xor buttons
        buttons = state
        for (bit in BUTTON_BITS) {
            if (changed and bit == 0) continue
            emit(mapOf("event" to if (state and bit != 0) "down" else "up", "button" to bit))
        }
    }

    private fun emit(payload: Map<String, Any>) {
        val out = sink ?: return
        activity.runOnUiThread { out.success(payload) }
    }

    fun dispose() {
        release()
        sink = null
        channel.setStreamHandler(null)
    }
}

private val BUTTON_BITS = intArrayOf(
    MotionEvent.BUTTON_PRIMARY,
    MotionEvent.BUTTON_SECONDARY,
    MotionEvent.BUTTON_TERTIARY,
)
