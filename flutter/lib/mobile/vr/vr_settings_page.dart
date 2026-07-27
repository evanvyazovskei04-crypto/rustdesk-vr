import 'package:flutter/material.dart';

import 'vr_calibration_page.dart';
import 'vr_session.dart';
import 'vr_settings.dart';

/// Cardboard VR settings and calibration.
///
/// Reachable with nothing connected: screen distance, lens coefficients and
/// virtual screen size are properties of a piece of plastic, not of a remote
/// machine, and tuning them before the first session is the ordinary case.
class VrSettingsPage extends StatefulWidget {
  const VrSettingsPage({Key? key, this.onEnterVr}) : super(key: key);

  /// Supplied when opened from a live session, so a change can be checked in the
  /// headset without walking back through the toolbar.
  final Future<void> Function()? onEnterVr;

  @override
  State<VrSettingsPage> createState() => _VrSettingsPageState();
}

class _VrSettingsPageState extends State<VrSettingsPage> {
  VrSettings get s => vr.settings;

  @override
  void initState() {
    super.initState();
    s.load().then((_) {
      if (mounted) setState(() {});
    });
  }

  void _changed(VoidCallback apply) {
    setState(apply);
    vr.touch();
  }

  Widget _slider({
    required String title,
    required String subtitle,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required String Function(double) label,
    required void Function(double) onChanged,
    required Future<void> Function() save,
  }) =>
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                    child: Text(title,
                        style: Theme.of(context).textTheme.titleMedium)),
                Text(label(value),
                    style: Theme.of(context).textTheme.titleMedium),
              ],
            ),
            Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
            Slider(
              value: value.clamp(min, max),
              min: min,
              max: max,
              divisions: divisions,
              onChanged: (v) => _changed(() => onChanged(v)),
              // Persisted on release, not on every frame of the drag, so a slow
              // drag does not rewrite the config a hundred times.
              onChangeEnd: (_) => save(),
            ),
          ],
        ),
      );

  Widget _mode(VrMode m, String subtitle) => RadioListTile<VrMode>(
        title: Text(m.label),
        subtitle: Text(subtitle),
        value: m,
        groupValue: s.mode,
        // Block body, NOT `() => vr.setMode(v)`: setMode returns a Future, and a
        // setState callback that RETURNS a Future makes setState throw after
        // running it but before scheduling the rebuild. The mode changed and
        // saved while the radio never repainted, which read as "the settings do
        // nothing until you leave the page and come back".
        onChanged: (v) {
          if (v == null) return;
          _changed(() {
            vr.setMode(v);
          });
        },
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Cardboard VR')),
      body: ListView(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: FilledButton.icon(
              icon: const Icon(Icons.threed_rotation),
              label: const Text('Calibrate in the headset'),
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => const VrCalibrationPage())),
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 6, 16, 10),
            child: Text(
                'Put the phone in the viewer first. Turn your head to set each '
                'value, tap the screen or click the mouse for the next one. '
                'Nothing needs to be connected — these belong to the headset, '
                'not to the remote machine.',
                style: TextStyle(fontSize: 12)),
          ),
          const Divider(),
          _mode(VrMode.mousePanning,
              'The Bluetooth mouse moves the cursor. The desktop is spread over a '
              'wide arc and you turn your head to look around it.'),
          _mode(VrMode.headPanning,
              'Your head moves the cursor and the centre reticle is the sight. '
              'Turn past a few degrees of slack and your head DRAGS the desktop, '
              'which then stays where you left it. Mouse MOVEMENT does nothing '
              'here — the buttons still click, and so does a tap on the panel '
              'from a Cardboard lever.'),
          _mode(VrMode.mouseLocked,
              'The mouse moves the cursor and the whole desktop stays in front of '
              'you instead of panning. Immune to gyro drift, but text is smaller.'),
          const Divider(),
          _slider(
            title: 'Head drag slack',
            subtitle:
                'In head mode, how far you can turn before your head starts '
                'dragging the desktop along. Inside the slack only the cursor '
                'moves, which is what lets you relax your neck without the view '
                'sliding back. Smaller drags sooner; larger keeps more of the '
                'desktop still while you aim.',
            value: s.headSlackDeg,
            min: 0.5,
            max: 30,
            divisions: 59,
            label: (v) => '${v.toStringAsFixed(1)}°',
            onChanged: (v) => s.headSlackDeg = v,
            save: s.saveHeadSlack,
          ),
          SwitchListTile(
            title: const Text('Pan to the corners'),
            subtitle: const Text(
                'Let the view keep travelling until a corner of the desktop sits '
                'in the middle of your view. Past the edge there is nothing to '
                'show, so that part goes black. With this off the corners stay '
                'off to the side, out of reach at any head angle.'),
            value: s.overscan,
            onChanged: (v) => _changed(() {
              s.overscan = v;
              s.saveOverscan();
            }),
          ),
          SwitchListTile(
            title: const Text('Edge push pans the view'),
            subtitle: const Text(
                'Mouse modes: hold the cursor against the edge of what you can '
                'see and the desktop scrolls under it, staying where you leave '
                'it. Head mode does not need this — there your head drags the '
                'desktop directly.'),
            value: s.edgePush,
            onChanged: (v) => _changed(() {
              s.edgePush = v;
              s.saveEdgePush();
            }),
          ),
          if (s.edgePush)
            _slider(
              title: 'Edge push speed',
              subtitle: 'How fast the view scrolls at a full push. Scaled by how '
                  'far into the edge you are, so a light touch creeps.',
              value: s.edgeRateDegPerSec,
              min: 5,
              max: 200,
              divisions: 39,
              label: (v) => '${v.round()}°/s',
              onChanged: (v) => s.edgeRateDegPerSec = v,
              save: s.saveEdgeRate,
            ),
          SwitchListTile(
            title: const Text('Screen tap clicks'),
            subtitle: const Text(
                'Treat a tap on the panel as a left click at the cursor — how a '
                'bare Cardboard viewer clicks, through its conductive lever. Hold '
                'to drag. Turn off if the viewer presses the panel by itself.'),
            value: s.touchClick,
            onChanged: (v) => _changed(() {
              s.touchClick = v;
              s.saveTouchClick();
            }),
          ),
          SwitchListTile(
            title: const Text('Full brightness in VR'),
            subtitle: const Text(
                'The viewer covers the light sensor, so auto-brightness reads '
                'darkness and dims the screen just when the lenses are already '
                'costing you light. Turn off if the phone gets hot.'),
            value: s.maxBrightness,
            onChanged: (v) => _changed(() {
              s.maxBrightness = v;
              s.saveBrightness();
            }),
          ),
          const Divider(),
          _slider(
            title: 'Screen distance (eye convergence)',
            subtitle:
                'How far away the screen feels. HIGHER brings the two images '
                'closer together, so your eyes converge more and the screen feels '
                'NEARER; lower pushes it away. If it still feels too close at the '
                'minimum, the viewer’s own lens-distance slider is the other '
                'control — that one sets the optical focus, which no software '
                'value can fix.',
            value: s.ipdPx,
            min: -60,
            max: 200,
            divisions: 52,
            label: (v) => '${v.round()} px',
            onChanged: (v) => s.ipdPx = v,
            save: s.saveIpd,
          ),
          _slider(
            title: 'Virtual screen width',
            subtitle:
                'How much arc the desktop covers. Wider means larger text and more '
                'room to pan, at the cost of more head movement.\n\nIt also sets '
                'the VERTICAL range, which is the surprising part: useful vertical '
                'travel needs roughly 110° × (desktop width / height) — about 200° '
                'for 16:9, but nearer 390° for a 32:9 ultrawide. Below that the top '
                'and bottom corners cannot reach the centre of view at any angle.',
            value: s.screenWidthDeg,
            min: 60,
            max: 540,
            divisions: 96,
            label: (v) => '${v.round()}°',
            onChanged: (v) => s.screenWidthDeg = v,
            save: s.saveScreenWidth,
          ),
          _slider(
            title: 'Field of view per eye',
            subtitle: 'How wide a slice each eye sees. Around 90° is typical for a '
                'Cardboard-class viewer.',
            value: s.eyeFovDeg,
            min: 40,
            max: 140,
            divisions: 50,
            label: (v) => '${v.round()}°',
            onChanged: (v) => s.eyeFovDeg = v,
            save: s.saveEyeFov,
          ),
          const Divider(),
          _slider(
            title: 'Mouse sensitivity',
            subtitle: 'Remote cursor travel per unit of physical mouse motion.',
            value: s.sensitivity,
            min: 0.2,
            max: 5,
            divisions: 48,
            label: (v) => '${v.toStringAsFixed(1)}×',
            onChanged: (v) => s.sensitivity = v,
            save: s.saveSensitivity,
          ),
          _slider(
            title: 'Head pointer dead zone',
            subtitle: 'How far the head must turn before the cursor moves. Raise it '
                'if the pointer creeps while you hold still on a target.',
            value: s.headDeadZoneDeg,
            min: 0,
            max: 2,
            divisions: 40,
            label: (v) => '${v.toStringAsFixed(2)}°',
            onChanged: (v) => s.headDeadZoneDeg = v,
            save: s.saveHeadDeadZone,
          ),
          _slider(
            title: 'Head smoothing',
            subtitle: 'Damps sensor noise. Raise it if the view jitters when you '
                'hold still, lower it if the picture lags behind your head.',
            value: s.smoothing,
            min: 0,
            max: 0.9,
            divisions: 18,
            label: (v) => v.toStringAsFixed(2),
            onChanged: (v) => s.smoothing = v,
            save: s.saveSmoothing,
          ),
          const Divider(),
          SwitchListTile(
            title: const Text('Lens correction'),
            subtitle: const Text(
                'Pre-warp the image so the viewer’s lenses, which bow straight '
                'lines outward, produce a rectilinear picture. Off by default: the '
                'right numbers belong to one piece of plastic, and a wrong '
                'correction looks worse than none.'),
            value: s.lensCorrect,
            onChanged: (v) async {
              _changed(() => s.lensCorrect = v);
              await s.saveLensCorrect();
              if (v) await vr.prepare();
              if (mounted) setState(() {});
            },
          ),
          if (s.lensCorrect) ...[
            SwitchListTile(
              title: const Text('Show calibration grid'),
              subtitle: const Text(
                  'Replaces the desktop with a square grid drawn through the same '
                  'warp — straightness is a far easier judgement than sharpness. '
                  'The orange dots come from the separate overlay maths: if they '
                  'sit on the crossings, the cursor lands where you aim.'),
              value: vr.grid,
              onChanged: (v) => _changed(() => vr.grid = v),
            ),
            _slider(
              title: 'Lens k1',
              subtitle: 'The main correction. Raise until straight lines stop '
                  'bowing outward; past the null they bow inward, which is more '
                  'objectionable, so creep up from below.',
              value: s.lensK1,
              min: 0,
              max: 0.6,
              divisions: 60,
              label: (v) => v.toStringAsFixed(2),
              onChanged: (v) => s.lensK1 = v,
              save: s.saveLensK1,
            ),
            _slider(
              title: 'Lens k2',
              subtitle: 'Fine correction at the far edges. Leave at 0 until k1 is '
                  'right, then use it if the corners still bow the opposite way to '
                  'the edge midpoints.',
              value: s.lensK2,
              min: VrSettings.lensK2Floor,
              max: 0.4,
              divisions: 50,
              label: (v) => v.toStringAsFixed(2),
              onChanged: (v) => s.lensK2 = v,
              save: s.saveLensK2,
            ),
            SwitchListTile(
              title: const Text('Force bilinear filtering'),
              subtitle: const Text(
                  'Binding a shader disables Flutter’s own texture filtering, '
                  'so the warped image may come out blocky on window borders. Turn '
                  'on if it does; it costs four texture reads per pixel.'),
              value: vr.bilinear,
              onChanged: (v) => _changed(() => vr.bilinear = v),
            ),
          ],
          const Divider(),
          ListTile(
            leading: const Icon(Icons.center_focus_strong),
            title: const Text('Recentre now'),
            subtitle: const Text(
                'Puts the view straight ahead and forgets anything your head has '
                'dragged. Also in the headset by holding the middle mouse button.'),
            onTap: vr.recentre,
          ),
          const ListTile(
            leading: Icon(Icons.mouse),
            title: Text('Mouse controls in VR'),
            subtitle: Text('middle + left: next mode\n'
                'middle + right: leave VR\n'
                'hold middle: recentre\n'
                'tap middle: ordinary middle click\n'
                'screen tap: left click at the cursor, hold to drag'),
          ),
          if (widget.onEnterVr != null)
            Padding(
              padding: const EdgeInsets.all(16),
              child: FilledButton.icon(
                icon: const Icon(Icons.vrpano),
                label: const Text('Back into VR'),
                onPressed: () async {
                  Navigator.of(context).pop();
                  await widget.onEnterVr!();
                },
              ),
            ),
        ],
      ),
    );
  }
}
