import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'vr_session.dart';
import 'vr_settings.dart';
import 'vr_stereo_view.dart';

/// One tunable pair. Yaw drives [a], pitch drives [b] where there is one.
class _Step {
  const _Step(this.title, this.a, [this.b]);
  final String title;
  final _Axis a;
  final _Axis? b;
}

class _Axis {
  const _Axis(this.label, this.read, this.write, this.save, this.perDegree,
      this.min, this.max,
      {this.decimals = 0, this.unit = ''});

  final String label;
  final double Function() read;
  final void Function(double) write;
  final Future<void> Function() save;

  /// Units per degree of head rotation, chosen so the whole useful range is a
  /// comfortable movement rather than a neck-craning sweep.
  final double perDegree;
  final double min, max;
  final int decimals;
  final String unit;

  String get pretty => '${read().toStringAsFixed(decimals)}$unit';
}

/// Calibrating a headset by dragging sliders means taking the headset off, which
/// is the one thing that makes the result unjudgeable. This walks the same values
/// with the viewer on: turn your head to set one, tap or click for the next.
class VrCalibrationPage extends StatefulWidget {
  const VrCalibrationPage({Key? key}) : super(key: key);

  @override
  State<VrCalibrationPage> createState() => _VrCalibrationPageState();
}

class _VrCalibrationPageState extends State<VrCalibrationPage> {
  static const _advanceDebounce = Duration(milliseconds: 400);

  late final List<_Step> _steps;
  int _index = 0;
  bool _gridWasOn = false;
  StreamSubscription? _mouseSub;
  DateTime _lastAdvance = DateTime.fromMillisecondsSinceEpoch(0);

  Offset _gazeAtEntry = Offset.zero;
  double _aAtEntry = 0, _bAtEntry = 0;

  bool get _finished => _index >= _steps.length;

  @override
  void initState() {
    super.initState();
    final s = vr.settings;
    _steps = [
      _Step(
        'Screen distance',
        _Axis('nearer / further', () => s.ipdPx, (v) => s.ipdPx = v, s.saveIpd,
            4.0, -60, 200, unit: ' px'),
      ),
      _Step(
        'Lens correction',
        _Axis('k1 (main)', () => s.lensK1, (v) => s.lensK1 = v, s.saveLensK1,
            0.015, 0, 0.6, decimals: 3),
        _Axis('k2 (edges)', () => s.lensK2, (v) => s.lensK2 = v, s.saveLensK2,
            0.0125, VrSettings.lensK2Floor, 0.4, decimals: 3),
      ),
      _Step(
        'Virtual screen',
        _Axis('width', () => s.screenWidthDeg, (v) => s.screenWidthDeg = v,
            s.saveScreenWidth, 8.0, 60, 540, unit: '°'),
        _Axis('field of view', () => s.eyeFovDeg, (v) => s.eyeFovDeg = v,
            s.saveEyeFov, 2.0, 40, 140, unit: '°'),
      ),
    ];
    _start();
  }

  Future<void> _start() async {
    _gridWasOn = vr.grid;
    vr.grid = true;
    vr.calibrating.value = true;
    await vr.prepare();
    vr.recentre();
    _snapshot();
    vr.head.gaze.addListener(_onGaze);

    // Take the mouse so its buttons come to us rather than moving an Android
    // pointer over a UI nobody can see. Read straight off the channel: VrInput
    // needs a session and the whole point here is not having one.
    await vr.capturePointer();
    _mouseSub = const EventChannel('rustdesk/vr_mouse')
        .receiveBroadcastStream()
        .listen((e) {
      if (e is Map && e['event'] == 'down') _advance();
    });

    await SystemChrome.setPreferredOrientations(
        [DeviceOrientation.landscapeLeft]);
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    if (mounted) setState(() {});
  }

  void _snapshot() {
    if (_finished) return;
    _gazeAtEntry = vr.head.gaze.value;
    _aAtEntry = _steps[_index].a.read();
    _bAtEntry = _steps[_index].b?.read() ?? 0;
  }

  /// Everything is measured in deltas from the head angle on entry, so nothing
  /// jumps to wherever the head happened to be pointing and returning to centre
  /// returns the value.
  void _onGaze() {
    if (_finished) return;
    final step = _steps[_index];
    final d = vr.head.gaze.value - _gazeAtEntry;
    step.a
        .write((_aAtEntry + d.dx * step.a.perDegree).clamp(step.a.min, step.a.max));
    // Pitch inverted, so looking up raises the number — the direction every
    // physical dial in the world agrees on.
    step.b?.write(
        (_bAtEntry - d.dy * step.b!.perDegree).clamp(step.b!.min, step.b!.max));
    vr.touch();
    if (mounted) setState(() {});
  }

  Future<void> _advance() async {
    // A Cardboard lever bounces, and a bounce that skips a whole step is
    // infuriating when the only way back is to start over.
    final now = DateTime.now();
    if (now.difference(_lastAdvance) < _advanceDebounce) return;
    _lastAdvance = now;
    if (_finished) return;

    final step = _steps[_index];
    await step.a.save();
    await step.b?.save();
    _index++;
    if (_finished) {
      // Reaching the end means the lens numbers were set deliberately, so turn the
      // correction on rather than leaving the user wondering why nothing changed.
      vr.settings.lensCorrect = true;
      await vr.settings.saveLensCorrect();
    } else {
      _snapshot();
    }
    if (mounted) setState(() {});
  }

  Future<void> _finish() async {
    vr.head.gaze.removeListener(_onGaze);
    await _mouseSub?.cancel();
    _mouseSub = null;
    await vr.releasePointer();
    await vr.release();
    vr.grid = _gridWasOn;
    vr.calibrating.value = false;
    await SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.manual,
        overlays: SystemUiOverlay.values);
  }

  @override
  void dispose() {
    vr.head.gaze.removeListener(_onGaze);
    _mouseSub?.cancel();
    vr.releasePointer();
    vr.release();
    vr.grid = _gridWasOn;
    vr.calibrating.value = false;
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.manual,
        overlays: SystemUiOverlay.values);
    super.dispose();
  }

  /// Kept short: this is read through plastic lenses, off axis, by someone who
  /// cannot lean in.
  List<String> get _hud {
    if (_finished) return ['saved — swipe back to leave'];
    final step = _steps[_index];
    return [
      '${_index + 1}/${_steps.length}  ${step.title}',
      'turn head:  ${step.a.label}  ${step.a.pretty}',
      if (step.b != null)
        'look up/down:  ${step.b!.label}  ${step.b!.pretty}',
      'tap or click for next',
    ];
  }

  @override
  Widget build(BuildContext context) {
    return WillPopScope(
      onWillPop: () async {
        await _finish();
        return true;
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: (_) => _advance(),
          child: VrStereoView(hud: _hud),
        ),
      ),
    );
  }
}
