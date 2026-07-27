import 'dart:async';
import 'dart:math';
import 'dart:ui';

import 'package:flutter/foundation.dart';

import '../../consts.dart';
import '../../models/input_model.dart';
import '../../models/model.dart';
import 'vr_geometry.dart';
import 'vr_settings.dart';
import 'vr_view.dart';

/// Coalescing interval for cursor motion. A gaming mouse can report at 1kHz, and
/// forwarding every sample would flood the session for no visible benefit.
const _flushInterval = Duration(milliseconds: 8);

/// The single owner of where the cursor is, and the only thing that talks to
/// [InputModel]. That is what lets a click land where the painter drew it.
///
/// Owns the cursor and nothing else -- where the VIEW is looking belongs to
/// [VrView]. Those two used to be tangled here, which is how a stored view came
/// to be half in one place and half in another.
///
/// Deltas come in relative but go out ABSOLUTE. Relative would have been more
/// direct, but the host never echoes back a position we commanded: run_pos in
/// src/server/input_service.rs sends CursorPosition with send_without(exclude)
/// where exclude is our own connection for 300ms, then updates cursor_pos
/// unconditionally, so once that window lapses is_moved() is already false and
/// nothing is sent. CursorModel therefore sits at -10000 for the whole time we
/// are driving, and anything needing to know where the cursor is must track it
/// itself. Absolute also drops any requirement that the host support relative
/// mouse mode.
class VrCursor {
  VrCursor({required this.ffi, required this.settings, required this.view});

  final FFI ffi;
  final VrSettings settings;
  final VrView view;

  /// Cursor position as a fraction of the remote display in each axis, or null
  /// before the first move.
  ///
  /// Normalised so the painter needs neither the display origin nor the
  /// display-to-frame scale. Those differ: FfiModel divides display lengths by
  /// display.scale for HiDPI peers, so rect.width is logical while the frame is
  /// physical, and subtracting the origin alone misplaces the cursor on exactly
  /// those hosts.
  final position = ValueNotifier<Offset?>(null);

  Timer? _timer;
  Offset? _remote;
  double _pendingDx = 0, _pendingDy = 0;
  bool? _hadPermission;
  bool _warnedNoRect = false;

  /// Whether the last tick panned by pushing. Edge push has to keep going while
  /// the cursor is merely *held* at the edge with no new mouse movement arriving,
  /// so the idle early-return cannot be purely about pending deltas.
  bool _edging = false;
  DateTime _lastEdgeLog = DateTime.fromMillisecondsSinceEpoch(0);

  void start() {
    _remote = null;
    position.value = null;
    _pendingDx = _pendingDy = 0;
    _edging = false;
    _timer ??= Timer.periodic(_flushInterval, (_) => flush());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _pendingDx = _pendingDy = 0;
    _edging = false;
    position.value = null;
  }

  /// Relative motion from a mouse. Ignored while the head drives the cursor: the
  /// two are alternatives, not a blend. Composing them was tried and rejected --
  /// it leaves no way to say what is driving the pointer at any moment.
  void addMouseDelta(double dx, double dy) {
    if (settings.mode.headDrivesCursor) return;
    _pendingDx += dx;
    _pendingDy += dy;
  }

  void scroll(double v) {
    // Android reports positive VSCROLL for a push away from the user, the same
    // direction RustDesk's scroll(1) means.
    if (v != 0) ffi.inputModel.scroll(v > 0 ? 1 : -1);
  }

  /// A button, at the current cursor.
  ///
  /// tapDown/tapUp carry no coordinates, so they act wherever the host thinks the
  /// cursor is. Buttons dispatch straight from their channel while motion waits
  /// for the coalescing timer, so without flushing first a click lands up to one
  /// interval of movement behind where the user is aiming.
  void button(MouseButtons b, bool down) {
    if (down) {
      flush();
      ffi.inputModel.tapDown(b);
    } else {
      ffi.inputModel.tapUp(b);
    }
  }

  /// Commit whatever the current inputs say the cursor should be.
  void flush() {
    final rect = ffi.ffiModel.rect;
    if (rect == null) {
      if (!_warnedNoRect) {
        _warnedNoRect = true;
        debugPrint('[vr] no display rect yet — the session has not reported '
            'displays, so there are no coordinates to move a cursor in');
      }
      return;
    }
    _warnedNoRect = false;

    final head = settings.mode.headDrivesCursor;
    final nudged = _pendingDx != 0 || _pendingDy != 0;
    if (!head && !nudged && !_edging) return;

    Offset target;
    if (head) {
      // VrView.aim already carries the parked view plus the head's position
      // inside the slack, so the cursor follows the head within a view that is
      // not moving. Computed there rather than here for the same reason it is not
      // computed in the painter: one owner per question.
      target = rect.topLeft + degreesInImage(view.aim, settings, rect.size);
    } else {
      var from = _remote;
      if (from == null) {
        // Start from wherever the host last reported the cursor so entering VR
        // does not teleport it. CursorModel parks it far off screen until the
        // first update, hence the containment check.
        final known = ffi.cursorModel.offset;
        from = rect.contains(known) ? known : rect.center;
      }
      target = from +
          Offset(_pendingDx * settings.sensitivity,
              _pendingDy * settings.sensitivity);
      _pendingDx = _pendingDy = 0;
    }

    // Clamped here rather than left to getPointInRemoteRect: with isLocalDesktop
    // false that helper returns null when *both* axes are out of range, which is
    // exactly what aiming past a corner produces -- it would send nothing and
    // leave the cursor short of the corner, the one place head pointing most
    // needs to reach.
    final clamped = Offset(
      target.dx.clamp(rect.left, rect.right),
      target.dy.clamp(rect.top, rect.bottom),
    );

    final p = InputModel.getPointInRemoteRect(
        false, ffi.ffiModel.pi.platform, kPointerEventKindMouse, '',
        clamped.dx, clamped.dy, rect);
    if (p == null) return;
    final committed = Offset(p.x, p.y);

    if (head) {
      // Dead zone on the COMMITTED position, not the raw target. A head trying to
      // hold still still wobbles a fraction of a degree, and comparing the raw
      // target would also resend the same clamped position forever while aiming
      // past the desktop edge.
      final last = _remote;
      if (last != null) {
        final slop =
            settings.headDeadZoneDeg * (rect.width / settings.screenWidthDeg);
        if ((committed - last).distance < slop) return;
      }
    }

    _warnIfNoPermission();

    // Store the clamped position, never the raw one: otherwise pushing against
    // an edge builds phantom offset that has to be unwound before the cursor
    // moves.
    _remote = committed;
    if (!head) _edgePush(rect, committed);
    ffi.inputModel.moveMouse(_remote!.dx, _remote!.dy);
    final out = _remote!;
    position.value = Offset(
      rect.width == 0 ? 0 : (out.dx - rect.left) / rect.width,
      rect.height == 0 ? 0 : (out.dy - rect.top) / rect.height,
    );
  }

  /// Pan the view while the mouse cursor is held against the edge of what is
  /// visible, so reaching the far side of a wide desktop does not need the full
  /// half-width of the virtual screen in neck rotation.
  ///
  /// Mouse modes only. Head mode does not need it -- the head already drags the
  /// view -- and this trigger could not work there anyway: the head-driven cursor
  /// stays within the slack of the reticle, never the half viewport ahead of it
  /// that sitting in an edge band requires.
  void _edgePush(Rect rect, Offset at) {
    // Throttled, and deliberately ahead of every guard below: a probe placed
    // after them can only report the path you already assumed was taken, which is
    // exactly how one debugging round was wasted.
    final now = DateTime.now();
    final log = now.difference(_lastEdgeLog).inMilliseconds > 250;
    if (log) _lastEdgeLog = now;

    _edging = false;
    if (!settings.edgePush || settings.edgeRateDegPerSec <= 0) return;
    if (!settings.mode.viewFollowsHead) return;

    final eye = view.eye;
    if (eye.isEmpty) {
      if (log) debugPrint('[vr] edge blocked: eye viewport not recorded yet');
      return;
    }

    final window = sourceRect(
        image: rect.size, eye: eye, view: view.direction.value, s: settings);

    // The test is against the visible DESKTOP CONTENT, not the window.
    //
    // With overscan the window deliberately hangs off the desktop, and the cursor
    // is clamped to the desktop -- so on an overhanging side the cursor can never
    // get within a band of the window's edge, and the push could never fire there
    // at all. Measured on device: a cursor at the desktop's corner sat 143px
    // inside a window starting at -143, giving fx=0 while the user pushed as hard
    // as the desktop allowed.
    final desktop = Rect.fromLTWH(0, 0, rect.width, rect.height);
    final content = window.intersect(desktop);
    if (content.isEmpty) return;
    final band = VrSettings.edgeBand * min(content.width, content.height);
    if (band <= 0) return;

    // Cursor in image coordinates; rect.topLeft is the display origin.
    final c = at - rect.topLeft;

    // Only pan toward desktop that is not on screen yet. Panning further into the
    // blank overhang is not what anyone means by shoving the cursor at an edge,
    // and it is also what made the vertical case look broken rather than
    // finished: with the window's height equal to the desktop's there is nothing
    // above or below to reveal, so the honest answer is to do nothing.
    double push(double lowGap, double highGap, bool moreLow, bool moreHigh) {
      if (moreLow && lowGap < band) return -(1 - (lowGap / band)).clamp(0.0, 1.0);
      if (moreHigh && highGap < band) return (1 - (highGap / band)).clamp(0.0, 1.0);
      return 0;
    }

    final fx = push(c.dx - content.left, content.right - c.dx,
        content.left > 0, content.right < desktop.right);
    final fy = push(c.dy - content.top, content.bottom - c.dy,
        content.top > 0, content.bottom < desktop.bottom);
    if (fx == 0 && fy == 0) return;

    // Hold the pushed position against the head before adding to it, or most of
    // what moves is the head's live contribution and springs back with the neck.
    view.foldHeadIntoStored();

    final step =
        settings.edgeRateDegPerSec * _flushInterval.inMicroseconds / 1e6;
    // Gaze pitch is inverted relative to image Y, so a downward push is negative
    // pitch -- the same convention sourceRect uses.
    final applied = view.nudge(Offset(fx * step, -fy * step));
    if (applied == Offset.zero) return;

    _edging = true;

    if (log) {
      debugPrint('[vr] edge fx=${fx.toStringAsFixed(2)} '
          'fy=${fy.toStringAsFixed(2)} band=${band.round()} '
          'cursor=${c.dx.round()},${c.dy.round()} '
          'content=${content.left.round()},${content.top.round()} '
          '${content.width.round()}x${content.height.round()} '
          'view=${view.direction.value.dx.toStringAsFixed(1)},'
          '${view.direction.value.dy.toStringAsFixed(1)}');
    }

    // Carry the cursor along so it stays pinned at the edge and the desktop
    // slides under it -- the familiar edge-scroll feel. Left behind, it would
    // drift back toward the middle, leave the band and stop after a few pixels.
    final pxPerDeg = rect.width / settings.screenWidthDeg;
    _remote = Offset(
      (_remote!.dx + applied.dx * pxPerDeg).clamp(rect.left, rect.right),
      (_remote!.dy - applied.dy * pxPerDeg).clamp(rect.top, rect.bottom),
    );
  }

  /// InputModel.moveMouse and sendMouse both open with `if (!keyboardPerm)
  /// return;`, so without that permission every move and click is discarded in
  /// silence: the local cursor still tracks, the logs still show input going out,
  /// and nothing reaches the host. From inside a headset that is
  /// indistinguishable from a broken VR mode, and it cost a debugging session to
  /// find out.
  void _warnIfNoPermission() {
    final allowed = ffi.ffiModel.keyboard;
    if (allowed == _hadPermission) return;
    _hadPermission = allowed;
    debugPrint(allowed
        ? '[vr] host granted mouse/keyboard control'
        : '[vr] host has NOT granted mouse/keyboard control — every move and '
            'click will be dropped silently');
  }
}
