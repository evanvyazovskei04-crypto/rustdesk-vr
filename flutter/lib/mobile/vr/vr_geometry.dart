import 'dart:math';
import 'dart:ui';

import 'vr_settings.dart';

/// Pure VR geometry: no Flutter widgets, no channels, no state.
///
/// Kept separate so the two places that must agree about it -- the painter,
/// which decides what you see, and the cursor, which decides where a click
/// lands -- derive from the same functions instead of two copies that drift.

/// The region of the desktop frame one eye sees.
///
/// [view] is the view direction in degrees (see VrView -- it is NOT raw gaze),
/// [eye] is one eye's viewport, [image] is the frame size.
Rect sourceRect({
  required Size image,
  required Size eye,
  required Offset view,
  required VrSettings s,
  Offset? follow,
}) {
  final imgW = image.width, imgH = image.height;
  if (!s.mode.viewFollowsHead) return Rect.fromLTWH(0, 0, imgW, imgH);

  // Spreading the desktop over screenWidthDeg of arc is what buys legible text:
  // each degree of head rotation covers fewer pixels, so every pixel takes up
  // more of the retina.
  final pxPerDeg = imgW / s.screenWidthDeg;
  var w = s.eyeFovDeg * pxPerDeg;
  var h = w * (eye.height / eye.width);

  // Never ask for more than exists, or the frame is letterboxed inside the
  // source rect and empty bands drift past as the head moves.
  if (w > imgW) {
    w = imgW;
    h = w * (eye.height / eye.width);
  }
  if (h > imgH) {
    h = imgH;
    w = h * (eye.width / eye.height);
  }

  final cx = imgW / 2 + view.dx * pxPerDeg;
  // Image Y grows downward, so looking up must decrease it.
  final cy = imgH / 2 - view.dy * pxPerDeg;

  double left, top;
  if (s.overscan) {
    // Clamp the view CENTRE, so a corner can be brought under the reticle. The
    // cost is honest: past the desktop edge there is nothing to show.
    left = cx.clamp(0.0, imgW) - w / 2;
    top = cy.clamp(0.0, imgH) - h / 2;
  } else {
    left = (cx - w / 2).clamp(0.0, max(0.0, imgW - w)).toDouble();
    top = (cy - h / 2).clamp(0.0, max(0.0, imgH - h)).toDouble();
  }

  // Keeping the cursor visible matters more than honouring the head angle
  // exactly: in a headset you cannot glance elsewhere to find it. Only ever
  // passed in head-pointer mode, where the cursor *is* the pointer.
  if (follow != null && follow.dx >= 0 && follow.dy >= 0) {
    final margin = min(w, h) * 0.1;
    if (follow.dx < left + margin) left = follow.dx - margin;
    if (follow.dx > left + w - margin) left = follow.dx - w + margin;
    if (follow.dy < top + margin) top = follow.dy - margin;
    if (follow.dy > top + h - margin) top = follow.dy - h + margin;
    if (s.overscan) {
      left = (left + w / 2).clamp(0.0, imgW) - w / 2;
      top = (top + h / 2).clamp(0.0, imgH) - h / 2;
    } else {
      left = left.clamp(0.0, max(0.0, imgW - w)).toDouble();
      top = top.clamp(0.0, max(0.0, imgH - h)).toDouble();
    }
  }

  return Rect.fromLTWH(left, top, w, h);
}

/// How far the view centre may sit from the desktop centre, in degrees.
///
/// The travel limit [sourceRect] will actually honour, expressed where the view
/// owner can apply it: a stored view beyond this is dead offset that has to be
/// unwound before the picture moves again, which is the phantom-offset trap.
/// With overscan that is the desktop half-size (either edge can come dead
/// ahead); without, the half-size eroded by half a viewport.
Offset viewLimitDeg({
  required Size image,
  required Size eye,
  required VrSettings s,
}) {
  final pxPerDeg = image.width / s.screenWidthDeg;
  if (s.overscan) {
    return Offset(image.width / 2 / pxPerDeg, image.height / 2 / pxPerDeg);
  }
  final win = sourceRect(image: image, eye: eye, view: Offset.zero, s: s);
  return Offset(
    max(0.0, image.width - win.width) / 2 / pxPerDeg,
    max(0.0, image.height - win.height) / 2 / pxPerDeg,
  );
}

/// A direction in degrees, as a point in the desktop frame.
///
/// The same pxPerDeg [sourceRect] uses -- that shared scale is what keeps the
/// cursor tracking the reticle. Not expressible as an aspect-free fraction:
/// both axes scale by image width over screenWidthDeg, so the vertical fraction
/// depends on the desktop's aspect ratio. Taking the image size makes that
/// explicit rather than hiding a wrong assumption.
Offset degreesInImage(Offset deg, VrSettings s, Size image) {
  final pxPerDeg = image.width / s.screenWidthDeg;
  return Offset(
    image.width / 2 + deg.dx * pxPerDeg,
    // Image Y grows downward, so looking up must decrease it.
    image.height / 2 - deg.dy * pxPerDeg,
  );
}

/// The radial lens map, in canvas logical pixels.
///
/// Forward, exactly as the shader does it: a point on the PANEL at radius r
/// shows the content that ideally belongs at
///   r_ideal = r (1 + k1 r^2 + k2 r^4) / (1 + k1 + k2)
/// so placing an overlay whose ideal position is known needs the inverse.
class LensWarp {
  LensWarp(this.k1, this.k2, this.rNorm, this.axis) : gainAtEdge = 1 + k1 + k2;

  final double k1, k2;

  /// Radius at which r == 1: the eye viewport's half-diagonal, i.e. the corner.
  final double rNorm;

  /// The optical axis: viewport centre shifted by the per-eye IPD offset.
  final Offset axis;

  /// g(1). Dividing by it pins r = 1 as a fixed point.
  final double gainAtEdge;

  bool get isIdentity => k1 == 0 && k2 == 0;

  double idealFromPanel(double r) =>
      r * (1 + k1 * r * r + k2 * r * r * r * r) / gainAtEdge;

  /// Stays positive across the allowed coefficient range; at zero the map folds
  /// and the image turns inside out at the edge.
  double slope(double r) =>
      (1 + 3 * k1 * r * r + 5 * k2 * r * r * r * r) / gainAtEdge;

  /// Panel position for a point whose undistorted position is known.
  ///
  /// Newton from the identity seed, which is exact at r = 1. Three iterations
  /// put the residual far below a tenth of a pixel across the whole allowed
  /// range, and this runs for a handful of points per eye rather than per
  /// fragment.
  Offset toPanel(Offset ideal) {
    final d = ideal - axis;
    final target = d.distance / rNorm;
    if (target <= 1e-6) return ideal;
    var r = target;
    for (var i = 0; i < 3; i++) {
      final s = slope(r);
      if (s.abs() < 1e-6) break;
      r -= (idealFromPanel(r) - target) / s;
    }
    return axis + d * (r / target);
  }

  /// Half-diagonal, never half-width: it keeps r under about 1.08 everywhere on
  /// the panel so the quartic term cannot overwhelm the quadratic, which is what
  /// lets k1 and k2 be tuned independently by eye.
  static double normFor(Rect viewport) =>
      sqrt(viewport.width * viewport.width + viewport.height * viewport.height) /
      2;
}
