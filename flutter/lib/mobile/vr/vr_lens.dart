import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

/// The compiled barrel pre-warp, loaded once per process.
class VrLens {
  VrLens._();

  /// Must match the path in pubspec.yaml's `shaders:` list exactly.
  static const _asset = 'shaders/vr_lens.frag';

  /// One shader per eye, never one shared between them.
  ///
  /// A CustomPainter records into a Picture rasterised later, so a Paint holds a
  /// reference to the shader rather than a snapshot of its uniforms. Sharing one
  /// would give both eyes the *second* eye's lens centre, which presents as one
  /// eye whose image is ipdPx away from its own reticle -- it reads as an IPD
  /// fault and gets tuned against for an hour.
  static ui.FragmentShader? left;
  static ui.FragmentShader? right;

  /// A 1x1 transparent image, bound as the sampler when the calibration grid is
  /// drawn with no video frame. The grid branch returns before it samples the
  /// frame, but a sampler must still be bound for the draw to be valid.
  static ui.Image? blank;

  static bool get ready => left != null && right != null && blank != null;

  /// Idempotent. A failure leaves everything null so the renderer degrades to the
  /// plain drawImageRect path: a missing or uncompilable shader must never present
  /// as a black screen nobody can diagnose from inside a viewer.
  static Future<void> load() async {
    if (ready) return;
    try {
      final program = await ui.FragmentProgram.fromAsset(_asset);
      left = program.fragmentShader();
      right = program.fragmentShader();
      final done = Completer<ui.Image>();
      ui.decodeImageFromPixels(
          Uint8List.fromList(const [0, 0, 0, 0]), 1, 1, ui.PixelFormat.rgba8888,
          done.complete);
      blank = await done.future;
    } catch (e) {
      debugPrint('[vr] lens shader unavailable, staying unwarped: $e');
    }
  }
}

/// Writes float uniforms in declaration order.
///
/// Flutter packs every float uniform into one flat index space in the order the
/// shader declares them, with vectors taking consecutive slots and samplers
/// indexed separately. Writing indices by hand is how inserting one scalar
/// silently shifts everything after it, and nothing throws: the buffer is sized
/// to the shader's own count, so any in-range index is accepted and the only
/// symptom is a plausible-looking wrong warp that reads as a bad k1.
class LensUniforms {
  LensUniforms(this._shader);

  final ui.FragmentShader _shader;
  int _i = 0;

  void v2(double a, double b) {
    _shader.setFloat(_i++, a);
    _shader.setFloat(_i++, b);
  }

  void v4(double a, double b, double c, double d) {
    _shader.setFloat(_i++, a);
    _shader.setFloat(_i++, b);
    _shader.setFloat(_i++, c);
    _shader.setFloat(_i++, d);
  }
}
