import 'dart:math';
import 'dart:ui';

import 'package:flutter/foundation.dart';

import 'vr_geometry.dart';
import 'vr_head.dart';
import 'vr_settings.dart';

/// The single owner of where the view is looking.
///
/// This class exists because the previous arrangement did not have one. The view
/// direction was assembled at the point of use as (gaze + pan), with `pan` owned
/// by the session and a separate held-view pair owned by the cursor, and the two
/// halves answered different questions: gaze reverses when the head comes back,
/// pan does not. Every "the screen bounced back" report traced to that split --
/// a position was stored in the half that reverses, and no amount of tuning the
/// push could fix where the number lived. So there is now exactly one direction,
/// one place that computes it, and one rule per mode for how the head feeds it.
///
/// Every mode is the same shape: a STORED view that survives head movement, plus
/// however much of the live head is allowed to leak through.
///
///   locked        stored is pinned at zero, no leak. The frame sits in front of
///                 the face.
///   mousePanning  the head leaks through 1:1, so the view tracks it like a
///                 window onto a fixed wall. Edge push moves the stored part.
///   headPanning   no leak. Head movement past [VrSettings.headSlackDeg] DRAGS
///                 the stored view instead, so what you look at is what you
///                 keep, and relaxing your neck inside the slack moves nothing.
///
/// Nothing here sends input or paints. [direction] is a [ValueNotifier] so the
/// painter can repaint at sensor rate without the video pipeline in the way.
class VrView {
  VrView({required this.settings, required this.head});

  final VrSettings settings;
  final VrHead head;

  /// Where the view centre points, in degrees. What the painter draws for, and
  /// what [sourceRect] takes as `view`.
  final direction = ValueNotifier<Offset>(Offset.zero);

  /// The stored part: what remains when the head returns to its reference.
  Offset _stored = Offset.zero;

  /// Head angle at which the head-mode cursor sits on the reticle. Null means
  /// "adopt the head's next sample", which is how entering the mode and
  /// recentring avoid jumping the picture.
  Offset? _anchor;

  VrMode? _lastMode;

  /// Travel limit in degrees, set from the frame and viewport once both are
  /// known. Zero means unknown, in which case nothing is clamped -- the first
  /// frame must not be pinned to the middle of the desktop.
  Offset _limit = Offset.zero;

  /// Where the head-driven pointer is aiming, in degrees.
  ///
  /// In head mode this is the view direction plus the head's position inside the
  /// slack, so the pointer moves within a parked view. In the mouse modes it is
  /// unused: the cursor is owned by mouse deltas, not by the head.
  Offset get aim => direction.value + _slackResidual;
  Offset _slackResidual = Offset.zero;

  void start() {
    reset();
    head.gaze.addListener(_onGaze);
  }

  void dispose() {
    head.gaze.removeListener(_onGaze);
  }

  /// Forget the stored view and re-adopt the head's next sample. Recentre is the
  /// single "put it back" gesture, so it must clear this too -- leaving a stored
  /// offset behind is precisely the mystery the user then has no gesture for.
  void reset() {
    _stored = Offset.zero;
    _anchor = null;
    _slackResidual = Offset.zero;
    direction.value = Offset.zero;
  }

  /// Called once the frame size and eye viewport are known. Cheap enough to call
  /// on every layout; it only recomputes a bound.
  void setBounds({required Size image, required Size eye}) {
    if (image.isEmpty || eye.isEmpty) return;
    _limit = viewLimitDeg(image: image, eye: eye, s: settings);
  }

  void _onGaze() => _recompute(head.gaze.value);

  /// Recompute after anything that changes the rules: a mode switch, or a
  /// calibration value that moves the travel limit.
  void refresh() => _recompute(head.gaze.value);

  void _recompute(Offset gaze) {
    final mode = settings.mode;
    if (mode != _lastMode) {
      _lastMode = mode;
      // Adopt the direction already on screen rather than snapping: switching
      // mode in a headset while the picture jumps is disorienting, and the chord
      // that switches modes is easy to hit by accident.
      _stored = direction.value;
      _anchor = null;
      _slackResidual = Offset.zero;
    }

    if (!mode.viewFollowsHead) {
      _slackResidual = Offset.zero;
      _publish(Offset.zero);
      return;
    }

    if (!mode.headDrivesCursor) {
      // The head leaks through 1:1. Nothing to store here; edge push is what
      // writes _stored in this mode.
      _slackResidual = Offset.zero;
      _publish(_stored + gaze);
      return;
    }

    // Head mode: drag through slack.
    //
    // The anchor is the head angle at which the pointer sits on the reticle.
    // Pressing more than the slack past it drags anchor AND stored view
    // together; moving inside it leaves both alone and only shifts the pointer.
    // Because the position lives in _stored rather than in live gaze, backing
    // the head off holds the picture still instead of springing it back.
    final anchor = _anchor ?? gaze;
    final w = max(0.0, settings.headSlackDeg);
    double drag(double g, double a) =>
        g > a + w ? g - w : (g < a - w ? g + w : a);
    final moved = Offset(drag(gaze.dx, anchor.dx), drag(gaze.dy, anchor.dy));

    final want = _stored + (moved - anchor);
    final got = _clamp(want);
    _stored = got;
    // The anchor tracks the head even where the view clamped, so a drag that ran
    // into the desktop edge costs nothing to reverse -- winding the anchor back
    // instead would make the head fight its way out of the stop.
    _anchor = moved;
    _slackResidual = gaze - moved;
    _publish(got);
  }

  /// Move the stored view directly, in degrees. Edge push in the mouse modes.
  ///
  /// Returns the amount actually applied, which is what lets the caller stop
  /// pushing against a stop rather than accumulating offset it must later unwind.
  Offset nudge(Offset delta) {
    if (!settings.mode.viewFollowsHead) return Offset.zero;
    final before = _stored;
    _stored = _clamp(_stored + delta);
    final applied = _stored - before;
    if (applied != Offset.zero) _recompute(head.gaze.value);
    return applied;
  }

  /// Move the head's live contribution into the stored view, leaving the
  /// direction exactly as it is.
  ///
  /// Only meaningful where the head leaks through, i.e. the mouse panning mode.
  /// Measured on device: pushing an edge is done while LOOKING that way, so most
  /// of the displacement was the head's 1:1 leak -- a stored -17.1 degrees was
  /// holding 182px of a 455px displacement and the other 273px sprang back with
  /// the neck. Worse, the head had already taken the view to its travel limit,
  /// so the push had nothing left to add and quit early. Folding leaves the
  /// picture untouched (the sum is what is drawn, and the sum does not change)
  /// while moving all of it into the part that persists, and hands the head a
  /// fresh centre to pan from.
  ///
  /// Sub-dead-zone gaze is left alone deliberately: absorbing gyro noise sixty
  /// times a second would random-walk it into a stored view that nothing damps
  /// back out.
  void foldHeadIntoStored() {
    if (settings.mode.headDrivesCursor || !settings.mode.viewFollowsHead) return;
    final g = head.gaze.value;
    final dead = settings.headDeadZoneDeg;
    if (g.dx.abs() <= dead && g.dy.abs() <= dead) return;
    _stored = _clamp(_stored + g);
    // head.recentre() zeroes gaze, so the published direction is unchanged.
    head.recentre();
    _recompute(Offset.zero);
  }

  Offset _clamp(Offset v) {
    if (_limit == Offset.zero) return v;
    return Offset(
      v.dx.clamp(-_limit.dx, _limit.dx),
      v.dy.clamp(-_limit.dy, _limit.dy),
    );
  }

  void _publish(Offset v) {
    if (direction.value != v) direction.value = v;
  }
}
