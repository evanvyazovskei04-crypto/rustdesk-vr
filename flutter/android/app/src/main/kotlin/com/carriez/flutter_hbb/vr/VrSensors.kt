package com.carriez.flutter_hbb.vr

import android.content.Context
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel

/**
 * Streams device orientation to Dart as a raw quaternion.
 *
 * Deliberately does no VR maths. Turning an orientation into a gaze direction
 * needs a recentre reference, smoothing and a sign convention, all of which want
 * tuning against a real headset -- and every change to them should cost a Dart
 * hot restart, not an Android rebuild.
 */
class VrSensors(context: Context, messenger: BinaryMessenger) {
    companion object {
        private const val LOG_TAG = "VrSensors"
        const val CHANNEL = "rustdesk/vr_orientation"
    }

    private val sensorManager =
        context.getSystemService(Context.SENSOR_SERVICE) as SensorManager

    /**
     * Game rotation vector first: it fuses gyro and accelerometer only, so it
     * carries no magnetometer jitter and is not pulled off by the magnets in many
     * Cardboard viewers or by a nearby speaker. Losing absolute compass heading
     * costs nothing here, because VR only ever uses orientation relative to
     * wherever the user last recentred.
     */
    private val sensor: Sensor? =
        sensorManager.getDefaultSensor(Sensor.TYPE_GAME_ROTATION_VECTOR)
            ?: sensorManager.getDefaultSensor(Sensor.TYPE_ROTATION_VECTOR)

    val available: Boolean get() = sensor != null

    private var sink: EventChannel.EventSink? = null
    private val quaternion = FloatArray(4)

    private val listener = object : SensorEventListener {
        override fun onSensorChanged(event: SensorEvent) {
            val out = sink ?: return
            SensorManager.getQuaternionFromVector(quaternion, event.values)
            // getQuaternionFromVector yields [w, x, y, z].
            out.success(
                listOf(
                    quaternion[0].toDouble(),
                    quaternion[1].toDouble(),
                    quaternion[2].toDouble(),
                    quaternion[3].toDouble(),
                )
            )
        }

        override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {}
    }

    private val channel = EventChannel(messenger, CHANNEL).apply {
        setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                sink = events
                val s = sensor
                if (s == null) {
                    Log.w(LOG_TAG, "no rotation vector sensor; head tracking unavailable")
                    return
                }
                // SENSOR_DELAY_GAME (~50Hz), not FASTEST: smooth enough for
                // panning without waking the CPU harder than necessary on a phone
                // that is already decoding video, sealed in a viewer with no
                // airflow.
                sensorManager.registerListener(listener, s, SensorManager.SENSOR_DELAY_GAME)
            }

            override fun onCancel(arguments: Any?) {
                sensorManager.unregisterListener(listener)
                sink = null
            }
        })
    }

    fun dispose() {
        sensorManager.unregisterListener(listener)
        sink = null
        channel.setStreamHandler(null)
    }
}
