import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Head orientation, as a gaze offset in degrees from a recentre reference.
///
/// Kotlin ships raw device quaternions; everything interpretive happens here.
class VrHead {
  static const _channel = EventChannel('rustdesk/vr_orientation');

  /// Gaze offset (yaw, pitch) in degrees relative to the recentre reference.
  ///
  /// A [ValueNotifier] on purpose, and deliberately not folded into a model the
  /// video also drives: the stereo painter has to repaint at display rate when
  /// the head moves even while video arrives a few frames a second. Coupling the
  /// two would make head motion feel as laggy as the slowest frame, which is the
  /// standard way to make a viewer queasy.
  final gaze = ValueNotifier<Offset>(Offset.zero);

  /// How heavily to damp; read from settings on each sample so a calibration
  /// slider takes effect live.
  double Function() smoothing = () => 0.25;

  StreamSubscription? _sub;

  double _yawRef = 0, _pitchRef = 0;
  bool _haveRef = false;
  double _yawRaw = 0, _pitchRaw = 0;
  double _yaw = 0, _pitch = 0;

  bool get listening => _sub != null;

  void start() {
    _haveRef = false;
    _yaw = _pitch = 0;
    gaze.value = Offset.zero;
    _sub ??= _channel.receiveBroadcastStream().listen(_onSample);
  }

  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
    gaze.value = Offset.zero;
  }

  /// Treat the current orientation as looking straight ahead. The main remedy
  /// for gyro drift, which is why it is also bound to a mouse chord.
  void recentre() {
    _yawRef = _yawRaw;
    _pitchRef = _pitchRaw;
    _haveRef = true;
    _yaw = _pitch = 0;
    gaze.value = Offset.zero;
  }

  void _onSample(dynamic event) {
    if (event is! List || event.length < 4) return;
    final w = (event[0] as num).toDouble();
    final x = (event[1] as num).toDouble();
    final y = (event[2] as num).toDouble();
    final z = (event[3] as num).toDouble();

    // Where the user is looking is the device's -Z axis rotated into world
    // space. Deriving yaw and pitch from that vector rather than from Euler
    // angles avoids the gimbal problems that show up when someone tilts their
    // head far up or down.
    final f = rotateVector(w, x, y, z, 0, 0, -1);

    // Android's world frame is east/north/up.
    _yawRaw = atan2(f[0], f[1]);
    _pitchRaw = asin(f[2].clamp(-1.0, 1.0));

    if (!_haveRef) {
      _yawRef = _yawRaw;
      _pitchRef = _pitchRaw;
      _haveRef = true;
    }

    // Wrapped, so crossing due north is not a 360 degree jump.
    final targetYaw = wrapPi(_yawRaw - _yawRef) * 180 / pi;
    final targetPitch = (_pitchRaw - _pitchRef) * 180 / pi;

    final alpha = (1.0 - smoothing()).clamp(0.02, 1.0);
    _yaw += (targetYaw - _yaw) * alpha;
    _pitch += (targetPitch - _pitch) * alpha;
    gaze.value = Offset(_yaw, _pitch);
  }

  /// Rotate (ux, uy, uz) by the unit quaternion (w, x, y, z).
  @visibleForTesting
  static List<double> rotateVector(double w, double x, double y, double z,
      double ux, double uy, double uz) {
    // v = u + 2 * cross(q, cross(q, u) + w * u)
    final tx = y * uz - z * uy + w * ux;
    final ty = z * ux - x * uz + w * uy;
    final tz = x * uy - y * ux + w * uz;
    return [
      ux + 2 * (y * tz - z * ty),
      uy + 2 * (z * tx - x * tz),
      uz + 2 * (x * ty - y * tx),
    ];
  }

  @visibleForTesting
  static double wrapPi(double a) {
    while (a > pi) {
      a -= 2 * pi;
    }
    while (a < -pi) {
      a += 2 * pi;
    }
    return a;
  }
}
