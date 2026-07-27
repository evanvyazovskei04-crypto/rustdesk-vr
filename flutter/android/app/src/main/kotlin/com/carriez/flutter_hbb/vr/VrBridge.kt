package com.carriez.flutter_hbb.vr

import android.app.Activity
import android.view.WindowManager
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * Everything the Flutter client cannot reach on its own once the phone is inside
 * a Cardboard viewer: head orientation, a captured mouse, and control of the
 * display so it neither sleeps nor dims.
 *
 * Wiring only. The two event streams live in [VrSensors] and [VrPointerCapture],
 * and all of the VR maths lives in Dart, so tuning the parts that actually want
 * iterating costs a hot restart rather than a Gradle build.
 */
class VrBridge(private val activity: Activity, messenger: BinaryMessenger) {
    companion object {
        const val CHANNEL = "rustdesk/vr"
    }

    private val sensors = VrSensors(activity, messenger)
    private val pointer = VrPointerCapture(activity, messenger)

    private val channel = MethodChannel(messenger, CHANNEL).apply {
        setMethodCallHandler { call, result ->
            when (call.method) {
                "hasRotationSensor" -> result.success(sensors.available)

                "isPointerCaptureSupported" ->
                    result.success(VrPointerCapture.supported)

                "capturePointer" -> result.success(pointer.capture())

                "releasePointer" -> {
                    pointer.release()
                    result.success(true)
                }

                "setVerbose" -> {
                    pointer.verbose = call.arguments as? Boolean ?: false
                    result.success(true)
                }

                "keepScreenOn" -> {
                    val on = call.arguments as? Boolean ?: false
                    if (on) {
                        activity.window.addFlags(
                            WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    } else {
                        activity.window.clearFlags(
                            WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    }
                    result.success(true)
                }

                "setBrightness" -> {
                    // A WINDOW override, never the system setting: no permission
                    // needed, nothing for the user to put back, and Android drops
                    // it by itself when this window goes away.
                    //
                    // Needed because auto-brightness works against a headset. The
                    // viewer covers the ambient light sensor, so it reads near-dark
                    // and dims the panel at exactly the moment the lenses are
                    // already absorbing much of the light. A null argument restores
                    // BRIGHTNESS_OVERRIDE_NONE.
                    val level = (call.arguments as? Number)?.toFloat()
                    activity.window.attributes = activity.window.attributes.apply {
                        screenBrightness =
                            level ?: WindowManager.LayoutParams.BRIGHTNESS_OVERRIDE_NONE
                    }
                    result.success(true)
                }

                else -> result.error("-1", "No such method", null)
            }
        }
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
        pointer.dispose()
        sensors.dispose()
    }
}
