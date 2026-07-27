import '../../models/platform_model.dart';

/// What drives the cursor, and what the view does.
///
/// Two decisions, not one, and every label names the pointer source first. A
/// mode that silently ignores mouse movement reads as a broken mouse otherwise
/// -- which is exactly how it got reported the first time round.
enum VrMode {
  /// Mouse moves the cursor; the view tracks the head 1:1 across a virtual
  /// screen wider than the headset's field of view. Spreading the desktop over
  /// that arc is what makes ordinary desktop text legible -- squeezed into ~90
  /// degrees each glyph is far too small.
  mousePanning,

  /// Head moves the cursor, and the view is DRAGGED by the head rather than
  /// strapped to it: it follows through a few degrees of slack
  /// ([headSlackDeg]) and then stays where the head leaves it. That is the
  /// whole point of the mode -- a position you look to is a position you keep,
  /// so backing your neck off does not throw the view back where it came from.
  /// Mouse *movement* is ignored; its buttons still click, as does a tap on the
  /// panel from a Cardboard viewer's conductive lever, which is all a bare
  /// viewer offers.
  headPanning,

  /// Mouse moves the cursor; the whole frame stays in front of the head instead
  /// of panning. Immune to gyro drift, but the text stays small.
  mouseLocked,
}

extension VrModeInfo on VrMode {
  /// Shown per eye inside the headset, pointer source first.
  String get label => switch (this) {
        VrMode.mousePanning => 'mouse · panning view',
        VrMode.headPanning => 'head · dragging view',
        VrMode.mouseLocked => 'mouse · locked view',
      };

  bool get headDrivesCursor => this == VrMode.headPanning;

  bool get viewFollowsHead => this != VrMode.mouseLocked;

  String get stored => switch (this) {
        VrMode.mousePanning => 'mousePanning',
        VrMode.headPanning => 'headPanning',
        VrMode.mouseLocked => 'mouseLocked',
      };

  /// Cycled by the in-headset chord, which is the only control available with
  /// the screen unreachable.
  VrMode get next => switch (this) {
        VrMode.mousePanning => VrMode.headPanning,
        VrMode.headPanning => VrMode.mouseLocked,
        VrMode.mouseLocked => VrMode.mousePanning,
      };
}

VrMode _modeFromStored(String s) => switch (s) {
      'headPanning' => VrMode.headPanning,
      'mouseLocked' => VrMode.mouseLocked,
      _ => VrMode.mousePanning,
    };

/// Persisted VR calibration, in the same local-option store the rest of the
/// mobile settings use so it survives restarts with no new mechanism.
///
/// Almost every value here belongs to one particular piece of plastic -- lens
/// spacing, lens-to-panel distance, panel width -- and none of them can be read
/// off the device, so all of them are tunable and none are constants.
class VrSettings {
  static const _kMode = 'vr-mode';
  static const _kIpd = 'vr-ipd-px';
  static const _kScreenWidth = 'vr-screen-width-deg';
  static const _kEyeFov = 'vr-eye-fov-deg';
  static const _kSensitivity = 'vr-mouse-sensitivity';
  static const _kSmoothing = 'vr-head-smoothing';
  static const _kHeadSlack = 'vr-head-slack-deg';
  static const _kHeadDeadZone = 'vr-head-dead-zone-deg';
  static const _kOverscan = 'vr-overscan';
  static const _kTouchClick = 'vr-touch-click';
  static const _kBrightness = 'vr-max-brightness';
  static const _kLens = 'vr-lens-correct';
  static const _kLensK1 = 'vr-lens-k1';
  static const _kLensK2 = 'vr-lens-k2';
  static const _kEdgePush = 'vr-edge-push';
  static const _kEdgeRate = 'vr-edge-rate';

  VrMode mode = VrMode.mousePanning;

  /// Convergence shift, in logical pixels -- NOT the separation between the
  /// images, despite what "eye separation" suggests.
  ///
  /// Each eye's image is shifted toward the screen centre by half this, so the
  /// gap between the two images is (eye viewport width - ipdPx). Raising it
  /// therefore brings the images CLOSER together, your eyes converge harder,
  /// and the screen appears NEARER. Lowering it pushes the screen away.
  /// Negative is allowed and pushes the images apart past their natural
  /// positions, for a viewer whose lenses want the screen further than 0 can
  /// manage -- though eyes diverge far less comfortably than they converge, so
  /// a little goes a long way.
  double ipdPx = 64;

  /// Angular width of the virtual screen.
  ///
  /// It governs the *vertical* range too, which is the non-obvious part: the
  /// screen's angular height is this times (desktop height / desktop width),
  /// and panning exists only where that exceeds the eye's vertical field of
  /// view. For 16:9 on a roughly square per-eye viewport, 150 degrees leaves
  /// about 3 degrees of vertical travel -- effectively none. 200 is usable; a
  /// 32:9 ultrawide needs nearer 390.
  double screenWidthDeg = 200;

  /// Angular width one eye sees through the lenses; ~90 for a Cardboard-class
  /// viewer.
  double eyeFovDeg = 90;

  /// Remote cursor travel per unit of physical mouse motion.
  double sensitivity = 1.0;

  /// 0 is raw sensor values, approaching 1 is heavily damped. Some smoothing
  /// removes gyro noise; too much feels like the world lagging behind the head,
  /// which is a reliable way to make someone queasy.
  double smoothing = 0.25;

  /// How far the head may turn before it starts dragging the view, in degrees.
  ///
  /// The control that makes [VrMode.headPanning] behave like dragging a map:
  /// inside the slack only the cursor moves, past it the view comes along, and
  /// letting the neck relax back inside costs nothing. Too small and every
  /// twitch shoves the scene; too large and the cursor reaches the slack edge
  /// before the view will budge.
  double headSlackDeg = 5;

  /// Head rotation below this does not move the cursor, so a head merely trying
  /// to hold still does not make the pointer creep.
  double headDeadZoneDeg = 0.15;

  /// Let the view travel until a desktop corner sits under the reticle.
  ///
  /// Bounding the source rect inside the desktop keeps every pixel filled, but
  /// it confines the view *centre* to the desktop eroded by half a viewport, so
  /// a corner can never be looked at straight on at any head angle. Clamping
  /// the centre instead trades empty space past the edge for corner reach.
  bool overscan = true;

  /// Hold the mouse cursor against the edge of what is visible to pan the
  /// desktop, instead of having to turn your head.
  ///
  /// Mouse modes only. [VrMode.headPanning] does not need it: the head already
  /// drags the view and what it drags stays put.
  bool edgePush = true;

  /// How fast the edge pushes, in degrees of view per second at full
  /// deflection. Scaled by how far into the edge band the cursor is, so a light
  /// touch creeps and a firm push moves.
  double edgeRateDegPerSec = 45;

  /// Fraction of the visible desktop counted as the edge band.
  static const double edgeBand = 0.08;

  /// Treat a tap on the panel as a left click at the cursor. This is how a bare
  /// Cardboard viewer clicks, through its conductive lever.
  bool touchClick = true;

  /// Hold the panel at full brightness.
  ///
  /// Not a preference: the viewer covers the ambient light sensor, so
  /// auto-brightness reads near-dark and dims the screen exactly when the
  /// lenses are already absorbing much of the light. Worth being able to turn
  /// off only because a sealed viewer running video and a shader at full
  /// brightness is a real thermal load.
  bool maxBrightness = true;

  /// Barrel pre-warp so the viewer's pincushioning lenses yield a rectilinear
  /// image. Off by default: the coefficients belong to one specific viewer and
  /// a wrong correction looks worse than none.
  bool lensCorrect = false;

  /// Radial coefficients in r_ideal = r(1 + k1 r^2 + k2 r^4) / (1 + k1 + k2),
  /// with r normalised so r == 1 at the eye viewport's half-diagonal, i.e. the
  /// panel corner.
  ///
  /// Both choices are load-bearing and only work together. Half-diagonal keeps
  /// r under about 1.08 anywhere on the panel, so the quartic never overwhelms
  /// the quadratic and the two can be nulled independently by eye. Dividing by
  /// g(1) pins r = 1 as a fixed point, so k1 reshapes without also zooming --
  /// [eyeFovDeg] already owns zoom, and two controls that both zoom cannot be
  /// tuned against each other. Because r = 1 is then the corner, the map takes
  /// the eye disc onto itself and introduces no black ring.
  ///
  /// Published Cardboard profiles are in tan-angle units and do NOT transfer:
  /// v2's 0.34/0.55 is wildly over-corrected here. Tune against the grid.
  double lensK1 = 0.22;
  double lensK2 = 0.0;

  /// k2 below this makes the map non-monotone before the far corner and the
  /// image folds inside out at the edge, with no other warning.
  static const double lensK2Floor = -0.10;

  Future<void> load() async {
    double num(String key, double fallback, double lo, double hi) {
      final v = double.tryParse(bind.mainGetLocalOption(key: key));
      if (v == null || v.isNaN) return fallback;
      return v.clamp(lo, hi).toDouble();
    }

    // Absent must not read as "off" for anything defaulting on.
    bool flag(String key, {required bool defaultOn}) {
      final raw = bind.mainGetLocalOption(key: key);
      return defaultOn ? raw != 'N' : raw == 'Y';
    }

    mode = _modeFromStored(bind.mainGetLocalOption(key: _kMode));
    ipdPx = num(_kIpd, 64, -60, 200);
    screenWidthDeg = num(_kScreenWidth, 200, 60, 540);
    eyeFovDeg = num(_kEyeFov, 90, 40, 140);
    sensitivity = num(_kSensitivity, 1.0, 0.2, 5);
    smoothing = num(_kSmoothing, 0.25, 0, 0.95);
    headSlackDeg = num(_kHeadSlack, 5, 0.5, 30);
    headDeadZoneDeg = num(_kHeadDeadZone, 0.15, 0, 2);
    overscan = flag(_kOverscan, defaultOn: true);
    touchClick = flag(_kTouchClick, defaultOn: true);
    maxBrightness = flag(_kBrightness, defaultOn: true);
    lensCorrect = flag(_kLens, defaultOn: false);
    lensK1 = num(_kLensK1, 0.22, 0, 0.6);
    lensK2 = num(_kLensK2, 0.0, lensK2Floor, 0.4);
    edgePush = flag(_kEdgePush, defaultOn: true);
    edgeRateDegPerSec = num(_kEdgeRate, 45, 0, 200);
  }

  Future<void> _setNum(String key, double v) =>
      bind.mainSetLocalOption(key: key, value: v.toString());

  Future<void> _setFlag(String key, bool v) =>
      bind.mainSetLocalOption(key: key, value: v ? 'Y' : 'N');

  Future<void> saveMode() =>
      bind.mainSetLocalOption(key: _kMode, value: mode.stored);
  Future<void> saveIpd() => _setNum(_kIpd, ipdPx);
  Future<void> saveScreenWidth() => _setNum(_kScreenWidth, screenWidthDeg);
  Future<void> saveEyeFov() => _setNum(_kEyeFov, eyeFovDeg);
  Future<void> saveSensitivity() => _setNum(_kSensitivity, sensitivity);
  Future<void> saveSmoothing() => _setNum(_kSmoothing, smoothing);
  Future<void> saveHeadSlack() => _setNum(_kHeadSlack, headSlackDeg);
  Future<void> saveHeadDeadZone() => _setNum(_kHeadDeadZone, headDeadZoneDeg);
  Future<void> saveOverscan() => _setFlag(_kOverscan, overscan);
  Future<void> saveTouchClick() => _setFlag(_kTouchClick, touchClick);
  Future<void> saveBrightness() => _setFlag(_kBrightness, maxBrightness);
  Future<void> saveLensCorrect() => _setFlag(_kLens, lensCorrect);
  Future<void> saveLensK1() => _setNum(_kLensK1, lensK1);
  Future<void> saveLensK2() => _setNum(_kLensK2, lensK2);
  Future<void> saveEdgePush() => _setFlag(_kEdgePush, edgePush);
  Future<void> saveEdgeRate() => _setNum(_kEdgeRate, edgeRateDegPerSec);
}
