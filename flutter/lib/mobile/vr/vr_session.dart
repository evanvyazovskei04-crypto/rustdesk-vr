import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

import '../../models/model.dart';
import 'vr_cursor.dart';
import 'vr_head.dart';
import 'vr_input.dart';
import 'vr_lens.dart';
import 'vr_settings.dart';
import 'vr_view.dart';

/// One VR session: the only thing the rest of the app talks to.
///
/// Holding the lifecycle in one place is what keeps the integration into
/// remote_page.dart down to a build branch and two calls. Teardown especially:
/// there are three ways out — the mouse chord, the back gesture, and the page
/// being disposed — and spreading them across the page and three models meant
/// writing the same teardown three times.
class VrSession {
  VrSession._() {
    view = VrView(settings: settings, head: head);
  }

  static final VrSession instance = VrSession._();

  static const _channel = MethodChannel('rustdesk/vr');

  /// Observed by the remote page to swap its body.
  final enabled = false.obs;

  /// Bumped whenever a calibration value changes, so views rebuild without every
  /// setting having to be individually observable.
  ///
  /// A ValueNotifier rather than an .obs because the stereo view merges it with
  /// the view direction and cursor into one Listenable, and GetX's Rx is not a
  /// Listenable.
  final revision = ValueNotifier<int>(0);

  final settings = VrSettings();
  final head = VrHead();

  /// The single owner of where the view is looking. See [VrView] — the split
  /// this replaces is what every "the screen bounced back" report came down to.
  late final VrView view;

  VrCursor? cursor;
  VrInput? input;

  /// Set while the in-headset calibration walk-through is running, so the stereo
  /// view knows to draw the grid and the step text.
  final calibrating = false.obs;

  /// Replaces the desktop with a rectilinear grid. Not persisted: it is a tuning
  /// aid, and a crash must not leave the next session staring at a grid.
  bool grid = false;

  /// Hand-rolled 4-tap bilinear inside the shader. Binding a shader silently
  /// drops Paint.filterQuality (setImageSampler takes no sampling options), so
  /// whether the frame is filtered at all is up to the backend and cannot be
  /// determined off-device. Not persisted, for the same reason it exists: it is a
  /// diagnostic.
  bool bilinear = false;

  bool get lensActive =>
      settings.lensCorrect &&
      VrLens.ready &&
      (settings.lensK1 != 0 || settings.lensK2 != 0);

  /// Whether the painter should take the shader path — also true while showing
  /// the grid, which is drawn by the same shader.
  bool get shaderActive => VrLens.ready && (lensActive || grid);

  Future<bool> get hasRotationSensor async =>
      await _channel.invokeMethod<bool>('hasRotationSensor') ?? false;

  Future<bool> get isCaptureSupported async =>
      await _channel.invokeMethod<bool>('isPointerCaptureSupported') ?? false;

  void touch() {
    revision.value++;
    // A changed calibration value can move the travel limit, so the view has to
    // re-clamp rather than wait for the next head sample.
    view.refresh();
  }

  /// Prepare head tracking, the display and the shader, without entering VR.
  ///
  /// Split out because calibration needs all of this and no session: what it
  /// tunes belongs to a piece of plastic, not to a remote machine.
  Future<void> prepare() async {
    await settings.load();
    head.smoothing = () => settings.smoothing;
    if (settings.lensCorrect || grid) await VrLens.load();
    head.start();
    view.start();
    await _channel.invokeMethod('keepScreenOn', true);
    if (settings.maxBrightness) {
      await _channel.invokeMethod('setBrightness', 1.0);
    }
    debugPrint('[vr] prepare mode=${settings.mode.stored} '
        'screenWidth=${settings.screenWidthDeg.round()}deg '
        'eyeFov=${settings.eyeFovDeg.round()}deg '
        'ipd=${settings.ipdPx.round()}px slack=${settings.headSlackDeg}deg '
        'overscan=${settings.overscan} touchClick=${settings.touchClick} '
        'lens=${settings.lensCorrect ? (VrLens.ready ? "k1=${settings.lensK1} k2=${settings.lensK2}" : "unavailable") : "off"}');
  }

  Future<void> release() async {
    view.dispose();
    await head.stop();
    await _channel.invokeMethod('keepScreenOn', false);
    // null restores BRIGHTNESS_OVERRIDE_NONE, handing control back to the system
    // immediately rather than at teardown.
    await _channel.invokeMethod('setBrightness', null);
  }

  Future<bool> capturePointer() async =>
      await _channel.invokeMethod<bool>('capturePointer') ?? false;

  Future<void> releasePointer() => _channel.invokeMethod('releasePointer');

  Future<void> setVerbose(bool v) => _channel.invokeMethod('setVerbose', v);

  /// Enter VR for a live session.
  Future<void> enter(FFI ffi, {required void Function() onExit}) async {
    if (enabled.isTrue) return;
    await prepare();

    final c = VrCursor(ffi: ffi, settings: settings, view: view);
    cursor = c;
    c.start();

    input = VrInput(
      cursor: c,
      settings: settings,
      onCycleMode: () => setMode(settings.mode.next),
      onRecentre: recentre,
      onExit: onExit,
    )..start();

    await capturePointer();
    await SystemChrome.setPreferredOrientations(
        [DeviceOrientation.landscapeLeft]);
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    enabled.value = true;
  }

  /// Leave VR. Safe to call more than once, which matters because there are three
  /// ways out and all of them route here.
  Future<void> exit() async {
    if (enabled.isFalse) return;
    enabled.value = false;
    // Release capture BEFORE dropping the subscription: releasing emits an up for
    // any button still held, and those have to reach Dart to be forwarded or the
    // host is left with a stuck button.
    await releasePointer();
    await input?.stop();
    input = null;
    cursor?.stop();
    cursor = null;
    await release();
    await SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.manual,
        overlays: SystemUiOverlay.values);
  }

  /// Teardown for a page being disposed, where awaiting is not an option.
  void abandon() {
    releasePointer();
    input?.stop();
    input = null;
    cursor?.stop();
    cursor = null;
    release();
    enabled.value = false;
  }

  /// The single "put it back" gesture: the head reference and the stored view go
  /// together. Recentring one and leaving the other is how an offset becomes a
  /// mystery the user has no gesture for.
  void recentre() {
    head.recentre();
    view.reset();
  }

  Future<void> setMode(VrMode m) async {
    debugPrint('[vr] mode -> ${m.stored}');
    settings.mode = m;
    // Re-anchor so a head-driven pointer starts under the reticle rather than
    // leaping to wherever the last recentre reference happens to put it. VrView
    // adopts the direction already on screen, so the picture does not jump.
    if (m.headDrivesCursor) head.recentre();
    touch();
    await settings.saveMode();
  }

  /// Android drops capture whenever the window loses focus, so anything that
  /// backgrounds the app silently kills the mouse until we ask again.
  Future<void> reacquire() async {
    if (enabled.isFalse) return;
    await capturePointer();
    input?.resetChords();
  }
}

final vr = VrSession.instance;
