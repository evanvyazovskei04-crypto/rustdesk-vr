import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/model.dart';
import 'vr_geometry.dart';
import 'vr_lens.dart';
import 'vr_session.dart';
import 'vr_settings.dart';

/// Side-by-side stereo presentation of the remote desktop.
///
/// The mobile client already decodes each frame into a [ui.Image] painted by a
/// CustomPainter, so a stereo pair costs no more than drawing that image twice
/// with different source rects — no GL surface, no platform texture, no extra
/// copy. Desktop uses a texture-based path instead; do not generalise from it.
class VrStereoView extends StatelessWidget {
  const VrStereoView({Key? key, this.hud}) : super(key: key);

  /// Lines shown per eye by the calibration walk-through. Null when just viewing.
  final List<String>? hud;

  @override
  Widget build(BuildContext context) {
    final image = Provider.of<ImageModel>(context);
    final cursor = Provider.of<CursorModel>(context);
    final ffiModel = Provider.of<FfiModel>(context);

    // View direction and the owned cursor are watched apart from the models
    // above, so head and mouse movement repaint at display rate rather than
    // video rate.
    return RepaintBoundary(
      // Bounds are recorded at layout rather than in paint(): the view owner
      // needs one eye's viewport to know how far it may travel, and layout is
      // the honest place to learn it.
      child: LayoutBuilder(builder: (context, constraints) {
        if (constraints.hasBoundedWidth && constraints.hasBoundedHeight) {
          final frame = image.image;
          vr.view.setBounds(
            image: frame == null
                ? Size.zero
                : Size(frame.width.toDouble(), frame.height.toDouble()),
            eye: Size(constraints.maxWidth / 2, constraints.maxHeight),
          );
        }
        return AnimatedBuilder(
          animation: Listenable.merge([
            vr.view.direction,
            vr.cursor?.position,
            vr.revision,
          ]),
          builder: (context, _) => CustomPaint(
            size: Size.infinite,
            painter: _StereoPainter(
              frame: image.image,
              cursorImage: cursor.image,
              cursorHotX: cursor.hotx,
              cursorHotY: cursor.hoty,
              ownCursor: vr.cursor?.position.value,
              inputAllowed: ffiModel.keyboard,
              view: vr.view.direction.value,
              settings: vr.settings,
              shaderLeft: vr.shaderActive ? VrLens.left : null,
              shaderRight: vr.shaderActive ? VrLens.right : null,
              blank: VrLens.blank,
              grid: vr.grid,
              bilinear: vr.bilinear,
              hud: hud,
            ),
          ),
        );
      }),
    );
  }
}

/// Drawing only. Every geometric decision comes from vr_geometry, so the painter
/// and the cursor cannot disagree about where things are, and the painter never
/// sends input — it repaints for reasons that have nothing to do with the head.
class _StereoPainter extends CustomPainter {
  _StereoPainter({
    required this.frame,
    required this.cursorImage,
    required this.cursorHotX,
    required this.cursorHotY,
    required this.ownCursor,
    required this.inputAllowed,
    required this.view,
    required this.settings,
    required this.shaderLeft,
    required this.shaderRight,
    required this.blank,
    required this.grid,
    required this.bilinear,
    required this.hud,
  });

  final ui.Image? frame;
  final ui.Image? cursorImage;
  final double cursorHotX, cursorHotY;

  /// The cursor this client owns, as a fraction of the display. The only
  /// trustworthy position: the host never echoes back a move we commanded.
  final Offset? ownCursor;

  final bool inputAllowed;

  /// Where the view is looking, in degrees — [VrView.direction], not raw gaze.
  final Offset view;

  final VrSettings settings;
  final ui.FragmentShader? shaderLeft, shaderRight;
  final ui.Image? blank;
  final bool grid, bilinear;
  final List<String>? hud;

  static const _gridPitch = 48.0;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    if (view.dx.isNaN || view.dy.isNaN) return;

    final eye = Size(size.width / 2, size.height);
    final half = settings.ipdPx / 2;
    final leftRect = Offset.zero & eye;
    final rightRect = Offset(eye.width, 0) & eye;
    final img = frame;

    if (img == null) {
      // Calibration must work with nothing connected: what it tunes belongs to
      // the viewer, not to a remote machine. The shader's grid branch returns
      // before it samples the frame, so it only needs *a* sampler bound.
      if (grid && shaderLeft != null && shaderRight != null && blank != null) {
        _gridOnly(canvas, leftRect, half, shaderLeft!);
        _gridOnly(canvas, rightRect, -half, shaderRight!);
      } else {
        _noSignal(canvas, leftRect, half);
        _noSignal(canvas, rightRect, -half);
      }
      return;
    }

    final imageSize = Size(img.width.toDouble(), img.height.toDouble());
    final follow = ownCursor == null
        ? null
        : Offset(ownCursor!.dx * imageSize.width,
            ownCursor!.dy * imageSize.height);
    final src = sourceRect(
      image: imageSize,
      eye: eye,
      view: view,
      s: settings,
      // In head-pointer mode keeping the cursor in view is not optional: the
      // cursor *is* the pointer, so losing sight of it loses control.
      follow: settings.mode.headDrivesCursor ? follow : null,
    );

    _eye(canvas, img, src, leftRect, half, shaderLeft);
    _eye(canvas, img, src, rightRect, -half, shaderRight);
  }

  void _eye(Canvas canvas, ui.Image img, Rect src, Rect viewport, double shiftX,
      ui.FragmentShader? shader) {
    canvas.save();
    canvas.clipRect(viewport);

    // Fit preserving aspect, so a desktop whose proportions differ from half the
    // phone screen is never stretched.
    final scale = min(viewport.width / src.width, viewport.height / src.height);
    final drawW = src.width * scale, drawH = src.height * scale;
    final dst = Rect.fromLTWH(
      viewport.left + (viewport.width - drawW) / 2 + shiftX,
      viewport.top + (viewport.height - drawH) / 2,
      drawW,
      drawH,
    );

    // ONE definition of the optical axis, shared by the frame warp, the cursor
    // and the reticle. That shared expression is what makes head-pointer aiming
    // survive the warp for free: the crosshair sits at r = 0, the map's fixed
    // point, so it cannot move.
    final axis = viewport.center.translate(shiftX, 0);
    final warp = (shader == null || !vr.lensActive)
        ? null
        : LensWarp(settings.lensK1, settings.lensK2, LensWarp.normFor(viewport),
            axis);

    if (warp == null || warp.isIdentity) {
      // With overscan the source rect can hang off the image, and drawImageRect
      // is undefined for a src outside its bounds. Draw the part that exists into
      // the matching part of dst; the overhang stays the black it already is.
      final visible = src.intersect(
          Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()));
      if (visible.width > 0 && visible.height > 0) {
        canvas.drawImageRect(
          img,
          visible,
          Rect.fromLTRB(
            dst.left + (visible.left - src.left) * scale,
            dst.top + (visible.top - src.top) * scale,
            dst.left + (visible.right - src.left) * scale,
            dst.top + (visible.bottom - src.top) * scale,
          ),
          Paint()..filterQuality = FilterQuality.medium,
        );
      }
    } else {
      _warped(canvas, img, src, dst, viewport, warp, shader!);
    }

    _pointer(canvas, img, src, dst, scale, warp);
    if (warp != null && grid) _gridProbes(canvas, viewport, warp);
    _reticle(canvas, axis);
    // HUD text is left unwarped deliberately: under this map an undistorted
    // overlay is perceived slightly further IN than drawn, which is the harmless
    // direction, and warping small text only softens it.
    _modeLabel(canvas, viewport, shiftX);
    if (!inputAllowed) _noInputWarning(canvas, viewport, shiftX);
    _hud(canvas, viewport, shiftX);

    canvas.restore();
  }

  void _warped(Canvas canvas, ui.Image img, Rect src, Rect dst, Rect viewport,
      LensWarp warp, ui.FragmentShader fs) {
    final iw = img.width.toDouble(), ih = img.height.toDouble();
    LensUniforms(fs)
      ..v2(warp.axis.dx, warp.axis.dy) //  0,1
      ..v2(warp.k1, warp.k2) //  2,3
      ..v2(1 / warp.rNorm, 1 / warp.gainAtEdge) //  4,5
      ..v4(dst.left, dst.top, dst.width, dst.height) //  6..9
      ..v4(src.left / iw, src.top / ih, src.width / iw, src.height / ih) // 10..13
      ..v2(1 / iw, 1 / ih) // 14,15
      ..v2(bilinear ? 1 : 0, grid ? _gridPitch : 0); // 16,17
    fs.setImageSampler(0, img);
    // The whole viewport, not dst: the warp pulls content inward, so the set of
    // panel pixels carrying image is not dst.
    canvas.drawRect(viewport, Paint()..shader = fs);
  }

  /// Exactly one cursor: our position, the host's bitmap.
  ///
  /// Drawing both would show two that disagree, and the host's own position is
  /// not merely late but never sent for moves we commanded, so CursorModel would
  /// pin its bitmap at -10000 all session. Stock CursorPaint is bypassed for the
  /// same reason it cannot be reused: it paints one overlay across the whole
  /// screen, which in stereo is a single cursor floating between the eyes. The
  /// ring is the fallback for a host that has sent no bitmap, or bakes the cursor
  /// into the video and never will.
  void _pointer(Canvas canvas, ui.Image img, Rect src, Rect dst, double scale,
      LensWarp? warp) {
    final c = ownCursor;
    if (c == null || c.dx.isNaN || c.dy.isNaN) return;
    final inImage =
        Offset(c.dx * img.width.toDouble(), c.dy * img.height.toDouble());
    if (!src.contains(inImage)) return;

    var at = Offset(
      dst.left + (inImage.dx - src.left) * scale,
      dst.top + (inImage.dy - src.top) * scale,
    );
    // The frame is resampled by the shader, so an unwarped cursor sits tens of
    // pixels from the desktop pixel it is actually over — zero at the axis, worst
    // near mid-radius. It is the one overlay that must land where the user
    // perceives it, so it goes through the same map, inverted.
    if (warp != null && !warp.isIdentity) at = warp.toPanel(at);

    final bmp = cursorImage;
    if (bmp != null) {
      // Clamped: at high magnification a 32px cursor would balloon, at low it
      // would vanish.
      final cs = scale.clamp(0.75, 3.0).toDouble();
      canvas.drawImageRect(
        bmp,
        Rect.fromLTWH(0, 0, bmp.width.toDouble(), bmp.height.toDouble()),
        Rect.fromLTWH(at.dx - cursorHotX * cs, at.dy - cursorHotY * cs,
            bmp.width * cs, bmp.height * cs),
        Paint()..filterQuality = FilterQuality.medium,
      );
      return;
    }
    canvas.drawCircle(
        at,
        7,
        Paint()
          ..color = const Color(0xCC00E5FF)
          ..strokeWidth = 2
          ..style = PaintingStyle.stroke);
    canvas.drawCircle(at, 1.5, Paint()..color = const Color(0xCC00E5FF));
  }

  /// A faint crosshair on the optical axis. It is the aiming sight in
  /// head-pointer mode, and the fixed "straight ahead" reference for recentring.
  void _reticle(Canvas canvas, Offset c) {
    final p = Paint()
      ..color = const Color(0x38FFFFFF)
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;
    const r = 7.0;
    canvas.drawLine(Offset(c.dx - r, c.dy), Offset(c.dx - 2, c.dy), p);
    canvas.drawLine(Offset(c.dx + 2, c.dy), Offset(c.dx + r, c.dy), p);
    canvas.drawLine(Offset(c.dx, c.dy - r), Offset(c.dx, c.dy - 2), p);
    canvas.drawLine(Offset(c.dx, c.dy + 2), Offset(c.dx, c.dy + r), p);
  }

  /// Probe dots at the ideal grid crossings, placed by the Dart inverse while the
  /// shader draws the lines by its own forward map.
  ///
  /// Two independent judgements from one screen: straight lines mean the
  /// coefficients fit the viewer, dots on the crossings mean the shader and the
  /// overlay code agree about the axis, the normalisation radius and the
  /// polynomial. The second class of bug is invisible against a desktop.
  void _gridProbes(Canvas canvas, Rect viewport, LensWarp warp) {
    final p = Paint()..color = const Color(0xCCFF3D00);
    for (var gy = -5; gy <= 5; gy++) {
      for (var gx = -5; gx <= 5; gx++) {
        final at = warp
            .toPanel(warp.axis.translate(gx * _gridPitch, gy * _gridPitch));
        if (!viewport.contains(at)) continue;
        canvas.drawCircle(at, 2, p);
      }
    }
  }

  void _gridOnly(
      Canvas canvas, Rect viewport, double shiftX, ui.FragmentShader fs) {
    canvas.save();
    canvas.clipRect(viewport);
    final axis = viewport.center.translate(shiftX, 0);
    final warp = LensWarp(settings.lensK1, settings.lensK2,
        LensWarp.normFor(viewport), axis);
    // uDst and uSrcUv go unread on the grid path but must still be finite: a NaN
    // reaching a uniform can take the whole draw out.
    LensUniforms(fs)
      ..v2(axis.dx, axis.dy)
      ..v2(warp.k1, warp.k2)
      ..v2(1 / warp.rNorm, 1 / warp.gainAtEdge)
      ..v4(viewport.left, viewport.top, viewport.width, viewport.height)
      ..v4(0, 0, 1, 1)
      ..v2(1, 1)
      ..v2(0, _gridPitch);
    fs.setImageSampler(0, blank!);
    canvas.drawRect(viewport, Paint()..shader = fs);
    _gridProbes(canvas, viewport, warp);
    _reticle(canvas, axis);
    _hud(canvas, viewport, shiftX);
    canvas.restore();
  }

  void _noSignal(Canvas canvas, Rect viewport, double shiftX) {
    canvas.save();
    canvas.clipRect(viewport);
    _reticle(canvas, viewport.center.translate(shiftX, 0));
    _text(canvas, viewport, shiftX, 'No remote session\nswipe back to leave VR',
        const Color(0x99FFFFFF), 13, viewport.center.dy + 24);
    canvas.restore();
  }

  static final Map<VrMode, TextPainter> _modeCache = {};

  /// The mode, small and faint. Inside a headset there is no toolbar, no toast
  /// and no way to check a setting, so without this the only way to tell which
  /// mode is active is to guess from behaviour — which is exactly what made a
  /// mode that was simply not selected look broken.
  void _modeLabel(Canvas canvas, Rect viewport, double shiftX) {
    final tp = _modeCache.putIfAbsent(
        settings.mode,
        () => TextPainter(
              text: TextSpan(
                  text: settings.mode.label,
                  style:
                      const TextStyle(color: Color(0x55FFFFFF), fontSize: 11)),
              textDirection: TextDirection.ltr,
            )..layout());
    tp.paint(
        canvas,
        Offset(viewport.center.dx + shiftX - tp.width / 2,
            viewport.bottom - tp.height - 10));
  }

  static final TextPainter _noInput = TextPainter(
    text: const TextSpan(
      text: 'no input permission\nallow control on the remote machine',
      style: TextStyle(color: Color(0xCCFF7043), fontSize: 12, height: 1.4),
    ),
    textAlign: TextAlign.center,
    textDirection: TextDirection.ltr,
  )..layout();

  /// Said out loud, because the alternative is concluding the whole feature is
  /// broken while the client works perfectly and the host discards everything it
  /// sends.
  void _noInputWarning(Canvas canvas, Rect viewport, double shiftX) {
    _noInput.paint(
        canvas,
        Offset(viewport.center.dx + shiftX - _noInput.width / 2,
            viewport.top + 24));
  }

  /// Calibration text. Not cached: the numbers change on every gaze tick, so a
  /// cache keyed by the string would miss every time and grow without bound.
  void _hud(Canvas canvas, Rect viewport, double shiftX) {
    final lines = hud;
    if (lines == null || lines.isEmpty) return;
    var y = viewport.center.dy + viewport.height * 0.12;
    for (var i = 0; i < lines.length; i++) {
      y = _text(
          canvas,
          viewport,
          shiftX,
          lines[i],
          i == 0 ? const Color(0xFFFFFFFF) : const Color(0xCCFFFFFF),
          i == 0 ? 15 : 13,
          y);
    }
  }

  double _text(Canvas canvas, Rect viewport, double shiftX, String s,
      Color colour, double size, double y) {
    final tp = TextPainter(
      text: TextSpan(
          text: s,
          style: TextStyle(color: colour, fontSize: size, height: 1.35)),
      textAlign: TextAlign.center,
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: viewport.width * 0.92);
    tp.paint(canvas, Offset(viewport.center.dx + shiftX - tp.width / 2, y));
    return y + tp.height + 3;
  }

  @override
  bool shouldRepaint(_StereoPainter old) =>
      old.frame != frame ||
      old.cursorImage != cursorImage ||
      old.ownCursor != ownCursor ||
      old.inputAllowed != inputAllowed ||
      old.view != view ||
      old.shaderLeft != shaderLeft ||
      old.grid != grid ||
      old.bilinear != bilinear ||
      !listEquals(old.hud, hud) ||
      // Calibration mutates settings in place, so identity is not enough.
      old.settings.mode != settings.mode ||
      old.settings.ipdPx != settings.ipdPx ||
      old.settings.screenWidthDeg != settings.screenWidthDeg ||
      old.settings.eyeFovDeg != settings.eyeFovDeg ||
      old.settings.overscan != settings.overscan ||
      old.settings.lensCorrect != settings.lensCorrect ||
      old.settings.lensK1 != settings.lensK1 ||
      old.settings.lensK2 != settings.lensK2;
}
