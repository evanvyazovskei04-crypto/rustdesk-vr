import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../models/input_model.dart';
import 'vr_cursor.dart';
import 'vr_settings.dart';

// MotionEvent.BUTTON_* on the Android side. Flutter's kPrimaryButton and friends
// happen to use the same bit values, so one mask feeds both paths.
const int buttonPrimary = 1;
const int buttonSecondary = 2;
const int buttonTertiary = 4;
const _bits = [buttonPrimary, buttonSecondary, buttonTertiary];

/// How long the middle button must be held before releasing it means "recentre"
/// rather than an ordinary middle click.
const _holdForCommand = Duration(milliseconds: 500);

/// Backstop for a touch-down whose up never arrives — a sticky Cardboard lever,
/// or a gesture the framework cancels. Long enough not to cut a real drag short.
const _touchStuckTimeout = Duration(seconds: 10);

/// Every way input reaches VR mode, funnelled into [VrCursor].
///
/// Three sources, because a headset can present any of them:
///  - captured mouse, over the platform channel;
///  - ordinary Flutter pointer events, for when capture is granted but silently
///    fails to deliver — that happened on an Android 10 Pixel and presented as
///    clicks working while nothing moved;
///  - a tap on the panel, which is the only input a bare Cardboard viewer has.
///
/// The captured and uncaptured paths are mutually guarded on whether a captured
/// event has ever actually arrived, so they can never both count the same motion.
class VrInput {
  VrInput({
    required this.cursor,
    required this.settings,
    required this.onCycleMode,
    required this.onRecentre,
    required this.onExit,
  });

  static const _channel = EventChannel('rustdesk/vr_mouse');

  final VrCursor cursor;
  final VrSettings settings;
  final void Function() onCycleMode;
  final void Function() onRecentre;
  final void Function() onExit;

  StreamSubscription? _sub;

  /// True once a captured event has actually arrived, as opposed to capture
  /// merely having been granted. Those are different claims and confusing them
  /// cost a session.
  bool _captureDelivering = false;

  int _uncapturedButtons = 0;

  bool _middleHeld = false;
  bool _middleWasChord = false;
  bool _middleHeldLong = false;
  Timer? _holdTimer;

  bool _touchHeld = false;
  Timer? _touchSafety;

  void start() {
    _captureDelivering = false;
    _uncapturedButtons = 0;
    _sub ??= _channel.receiveBroadcastStream().listen(_onPlatformEvent);
  }

  Future<void> stop() async {
    // Release a lever-held button first, or the host is left mid-drag with no way
    // for us to finish it.
    onTouchUp();
    _touchSafety?.cancel();
    _touchSafety = null;
    _holdTimer?.cancel();
    _holdTimer = null;
    await _sub?.cancel();
    _sub = null;
    resetChords();
  }

  /// Android drops pointer capture whenever the window loses focus, and the
  /// button-up that would have ended a chord is never delivered. Without this a
  /// middle button held at that moment stays "held" forever and silently
  /// swallows every later click as a chord.
  void resetChords() {
    _holdTimer?.cancel();
    _holdTimer = null;
    _middleHeld = false;
    _middleWasChord = false;
    _middleHeldLong = false;
    _uncapturedButtons = 0;
  }

  void _onPlatformEvent(dynamic event) {
    if (event is! Map) return;
    switch (event['event']) {
      case 'capture':
        debugPrint('[vr] pointer capture active=${event['active']}');
        break;
      case 'move':
        if (!_captureDelivering) {
          _captureDelivering = true;
          debugPrint('[vr] captured mouse events are flowing');
        }
        cursor.addMouseDelta((event['dx'] as num?)?.toDouble() ?? 0,
            (event['dy'] as num?)?.toDouble() ?? 0);
        break;
      case 'down':
      case 'up':
        _captureDelivering = true;
        final bit = (event['button'] as num?)?.toInt() ?? 0;
        final down = event['event'] == 'down';
        debugPrint('[vr] ${_name(bit)} ${down ? 'down' : 'up'}'
            '${_middleHeld ? ' (chord)' : ''}');
        _button(bit, down);
        break;
      case 'scroll':
        cursor.scroll((event['v'] as num?)?.toDouble() ?? 0);
        break;
    }
  }

  static String _name(int bit) => switch (bit) {
        buttonPrimary => 'left',
        buttonSecondary => 'right',
        buttonTertiary => 'middle',
        _ => 'button$bit',
      };

  /// Middle doubles as a modifier, because in a headset the screen is
  /// unreachable and every control has to arrive through the mouse:
  ///
  ///   middle + left    next mode
  ///   middle + right   leave VR
  ///   middle held      recentre
  ///   middle tapped    ordinary middle click, forwarded
  void _button(int bit, bool down) {
    if (bit == buttonTertiary) {
      if (down) {
        _middleHeld = true;
        _middleWasChord = false;
        _middleHeldLong = false;
        _holdTimer?.cancel();
        _holdTimer = Timer(_holdForCommand, () => _middleHeldLong = true);
      } else {
        _holdTimer?.cancel();
        _holdTimer = null;
        _middleHeld = false;
        if (_middleWasChord) {
          // Already did something; swallow the click.
        } else if (_middleHeldLong) {
          onRecentre();
        } else {
          // A plain middle click, delayed by however long it was held — for a
          // real click, imperceptible.
          cursor.button(MouseButtons.wheel, true);
          cursor.button(MouseButtons.wheel, false);
        }
        _middleHeldLong = false;
      }
      return;
    }

    if (_middleHeld) {
      if (down) {
        _middleWasChord = true;
        if (bit == buttonPrimary) {
          onCycleMode();
        } else if (bit == buttonSecondary) {
          onExit();
        }
      }
      // Swallow press and release both, so a chord never reaches the host as a
      // click.
      return;
    }

    final b = switch (bit) {
      buttonPrimary => MouseButtons.left,
      buttonSecondary => MouseButtons.right,
      buttonTertiary => MouseButtons.wheel,
      _ => null,
    };
    if (b != null) cursor.button(b, down);
  }

  // --- ordinary Flutter pointer events, for when capture does not deliver ---

  void onUncapturedMove(Offset delta) {
    if (_captureDelivering) return;
    cursor.addMouseDelta(delta.dx, delta.dy);
  }

  void onUncapturedButtons(int mask) {
    if (_captureDelivering) return;
    final changed = mask ^ _uncapturedButtons;
    _uncapturedButtons = mask;
    for (final bit in _bits) {
      if (changed & bit == 0) continue;
      _button(bit, mask & bit != 0);
    }
  }

  // --- the panel itself, which is all a bare Cardboard viewer offers ---

  /// A click at the current cursor from a source carrying no position of its own.
  /// Down and up stay separate so holding the lever drags.
  void onTouchDown() {
    if (!settings.touchClick) return;
    // A second finger is not a second click: a lever can only ever make one
    // contact, so anything beyond the first is the user handling the phone.
    if (_touchHeld) return;
    _touchHeld = true;
    _touchSafety?.cancel();
    _touchSafety = Timer(_touchStuckTimeout, onTouchUp);
    cursor.button(MouseButtons.left, true);
  }

  void onTouchUp() {
    if (!_touchHeld) return;
    _touchHeld = false;
    _touchSafety?.cancel();
    _touchSafety = null;
    cursor.button(MouseButtons.left, false);
  }
}
