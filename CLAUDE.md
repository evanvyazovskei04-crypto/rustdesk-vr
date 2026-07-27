# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

**Read [AGENTS.md](AGENTS.md) too.** It carries upstream RustDesk's directory
layout, Rust and Tokio rules, editing hygiene and the localization workflow, all
of which still apply. This file covers only what is specific to this fork.

## What this repo is

A fork of [RustDesk](https://github.com/rustdesk/rustdesk) at tag **1.4.9**, adding
a Cardboard-VR viewing mode and Bluetooth-mouse support to the **Android** client,
so a remote desktop can be viewed through a phone-in-a-headset viewer and driven
with a physical mouse.

This is a **divergent fork, not a contribution queue.** There is no intention of
upstreaming, so it is a standalone repository rather than a GitHub fork, work lands
on `main`, and upstream is a plain git remote (`git fetch upstream`) used for
rebasing onto a newer tag. Nothing here should be shaped around what upstream would
accept.

Everything this fork adds is **Dart and Kotlin**. Nothing under `src/` (the Rust
core), `flutter/lib/desktop/` or `flutter/lib/web/` is touched — and the reason is
not merge cleanliness but that **the Rust core cannot be rebuilt here at all.**
`librustdesk.so` is a prebuilt binary lifted from the official release APK, so a
change under `src/` would compile into nothing and silently not take effect.

The Dart layer is a third pass. The first accreted over 35 commits of discovery.
The second was written once with the requirements settled — and still got the view
model wrong, which took a day of hardware testing to find. This one keeps the build
scaffolding and the Kotlin bridge from the second (neither was ever implicated) and
rewrites the Dart against behaviour verified on the device, with one owner for
where the view is looking. Upstream's UI is kept as-is — only the VR layer is ours.

## Build

The Rust core is **not** compiled. `librustdesk.so` is lifted from the matching
official release APK, which removes the NDK, vcpkg and cargo-ndk entirely.

```bash
source scripts/dev_env.sh
```

First-time setup, **in this order** — `pub get` must precede the bridge codegen or
ffigen dies on a missing `.dart_tool/package_config.json`:

```bash
git submodule update --init --recursive --depth 1
```

```bash
cargo fetch
```

```bash
cd flutter && flutter pub get && cd ..
```

```bash
flutter_rust_bridge_codegen --rust-input ./src/flutter_ffi.rs --dart-output ./flutter/lib/generated_bridge.dart
```

```bash
./scripts/fetch_prebuilt_native_libs.sh
```

Then, from `flutter/`:

```bash
flutter build apk --debug --target-platform android-arm64
```

```bash
adb install -r build/app/outputs/flutter-apk/app-debug.apk
```

```bash
adb logcat -s VrSensors:V VrPointerCapture:V flutter:V
```

Analyze just this fork's code — a whole-project run is noisy with pre-existing
findings:

```bash
cd flutter && flutter analyze lib/mobile/vr lib/mobile/pages/remote_page.dart
```

arm64 only. Each other ABI needs its own matching release APK fetched, for no
benefit on a modern phone. Incremental builds are ~20s.

### Pins and traps

- **Flutter 3.24.5 exactly** (what upstream CI pins). Newer Dart rejects this
  pubspec.
- **JDK 17, not the system JDK.** The Gradle wrapper is 7.6.4, predating Java 21.
  `JAVA_HOME` alone is *not enough* — Flutter prefers Android Studio's bundled JDK,
  so `flutter config --jdk-dir="$JAVA_HOME"` is what takes effect. `flutter doctor`
  may still report the wrong one; trust the build.
- **`flutter/lib/generated_bridge.dart` is gitignored** and must be generated
  before any build. Needs `flutter_rust_bridge_codegen` **1.80.1** (matching
  `flutter_rust_bridge = "=1.80"` in `Cargo.toml`) plus `cbindgen`, and must run
  **from the repo root** — from `flutter/` it resolves `--rust-input` wrongly and
  fails with a bare "No such file or directory".
- **`libs/hbb_common` is a submodule.** Without it `cargo metadata` fails, which
  breaks both the codegen and Gradle's configuration phase.
- **`cargo fetch` is a build prerequisite.** `app/build.gradle` shells out to
  `cargo metadata` at configuration time to locate `rustls-platform-verifier`'s
  Android Maven directory. No Rust is compiled.
- **protoc is pinned forward to 3.21.12.** Upstream's 3.20.1 `osx-aarch_64`
  artifact contains an x86_64 binary, so `:app:generateDebugProto` dies with "Bad
  CPU type in executable" on Apple Silicon without Rosetta 2. The codegen cannot be
  skipped — `KeyboardKeyEventMapper.kt` consumes `hbb.MessageOuterClass`.

### The prebuilt-`.so` rule

The release version and the source tree **must match**: the flutter_rust_bridge
surface is generated from `src/flutter_ffi.rs` at a specific revision, and a
mismatched pair crashes deep inside the bridge looking unrelated to whatever you
changed. `scripts/fetch_prebuilt_native_libs.sh` defaults its version to
`Cargo.toml`'s, so **re-run it if you bump the tag**.

Only `librustdesk.so` and `libc++_shared.so` are copied. The release APK also has
`libapp.so` and `libflutter.so` — Flutter's own artifacts, which our build
regenerates; copying them would ship upstream's compiled Dart over ours.

Note the rename: cargo produces `liblibrustdesk.so` (the crate is `librustdesk`),
but jniLibs and `DynamicLibrary.open` both want `librustdesk.so`.

### Names the prebuilt `.so` binds to

Anything the `.so` resolves by name is frozen. Check rather than guess:

```bash
nm -D flutter/android/app/src/main/jniLibs/arm64-v8a/librustdesk.so | grep Java_
```

Exports are `Java_ffi_FFI_*`, so the load-bearing names are **`ffi.FFI`** — the
package `ffi` and object `FFI` in `kotlin/ffi.kt`; rename either and every
`external fun` throws `UnsatisfiedLinkError` at first use with nothing failing at
compile time — plus the **`rust*` callback names** Rust invokes on objects Kotlin
hands it.

`com.carriez.flutter_hbb` is **not** among them; the string does not occur in the
`.so` at all. It must still match the legacy `package` attribute in
`AndroidManifest.xml`, because components are declared relatively
(`android:name=".MainActivity"`) and the generated `R` class lands in it, used
unqualified from `MainService.kt` and `FloatingWindowService.kt`.

With no `namespace` set, that attribute *is* AGP's namespace. So `app/src/debug/`
and `app/src/profile/AndroidManifest.xml` each declare the same `package` and must
keep matching `main`; an AGP 8 migration's `namespace` must be the Kotlin package,
never the applicationId; and `adb` component targets cannot use the
`pkg/.Activity` shorthand:

```bash
adb shell am start -n com.carriez.flutter_hbb.vr/com.carriez.flutter_hbb.MainActivity
```

### Application id

`applicationId` is `com.carriez.flutter_hbb.vr`, so this installs **alongside**
official RustDesk rather than being rejected as a same-id update signed with a
different key. Consequences, all inherent to being a separate app: its own private
storage and therefore its own RustDesk ID; accessibility must be granted again
(listed as `RustDesk VR Input`); both apps register `rustdesk://` so links raise a
chooser.

**Do not "fix" the chooser by renaming the scheme.** `get_uri_prefix()` in
`src/common.rs` derives from the app name and is compiled into the prebuilt `.so`,
so `mainUriPrefixSync()` stays `rustdesk://`. Rename the manifest scheme and the
fork keeps *emitting* and QR-accepting `rustdesk://` links it can no longer
*receive*.

## Captured mouse input: two things that are not negotiable

Both were found on hardware after several wrong theories, and neither produces an
error of any kind when wrong — the mouse simply does nothing in VR while working
perfectly everywhere else.

- **Own the focused view.** Captured events go to the *focused* view via
  `View.dispatchCapturedPointerEvent`. There is no Activity-level hook — it is a
  View method, and overriding it on the Activity does not compile.
  `setOnCapturedPointerListener` on the FlutterView only works when FlutterView
  happens to hold focus: true on Android 17, false on an Android 10 Pixel.
  `VrPointerCapture.CapturePad` is a 1x1 focusable view we add and focus ourselves,
  and its focus request is **posted**, because `requestFocus()` fails on a view
  added but not yet laid out.
- **Read both delta fields.** Under capture the source becomes
  `SOURCE_MOUSE_RELATIVE` (`131076` = `0x20004`), but which field carries the
  movement varies by device. Measured on that Pixel:

  ```
  captured[3] source=131076 action=2 buttons=0 relX=0.0 relY=0.0 x=3.80 y=12.67
  ```

  `AXIS_RELATIVE_X/Y` are **always zero** there and the delta is in `getX()/getY()`;
  on other devices it is the reverse.

`VrPointerCapture` dumps the first five captured events with both candidate fields.
**Read that dump before theorising** — this is not settleable from documentation,
and reasoning about it instead of printing it cost three rounds.

## Architecture

Kotlin → Dart, one direction. Kotlin ships raw quaternions and raw deltas and does
no VR maths, so the parts worth iterating on cost a hot restart, not a Gradle
build.

`flutter/android/.../flutter_hbb/vr/` — `VrSensors` (orientation),
`VrPointerCapture` (the mouse), `VrBridge` (method channel + wiring), constructed
from `MainActivity.configureFlutterEngine`.

| Channel | Kind | Payload |
| --- | --- | --- |
| `rustdesk/vr_orientation` | event | device quaternion `[w,x,y,z]` |
| `rustdesk/vr_mouse` | event | `{event: move/down/up/scroll/capture, …}` |
| `rustdesk/vr` | method | capture, release, keepScreenOn, setBrightness, probes |

`flutter/lib/mobile/vr/`:

- **`vr_settings.dart`** — persisted calibration and `VrMode`. Data only.
- **`vr_head.dart`** — quaternion → gaze, as a `ValueNotifier`.
- **`vr_geometry.dart`** — pure functions: `sourceRect`, `viewLimitDeg`,
  `degreesInImage`, `LensWarp`. No widgets, channels or state.
- **`vr_view.dart`** — the single owner of **where the view is looking**. Read the
  next section before touching it.
- **`vr_lens.dart`** — shader loading and uniform writing.
- **`vr_cursor.dart`** — the single owner of where the **cursor** is, and the only
  caller of `InputModel`.
- **`vr_input.dart`** — the three input sources and the chord machine.
- **`vr_session.dart`** — `vr`, the lifecycle facade everything else talks to.
- **`vr_stereo_view.dart`** — widget + painter, drawing only.
- **`vr_settings_page.dart`**, **`vr_calibration_page.dart`** — the two calibration
  surfaces.

Integration is a build branch, a toolbar button and three lifecycle calls in
`remote_page.dart`.

### The view model: one owner, and why

**This is the thing to understand before changing anything about panning.** It cost
a full day of hardware testing across two rewrites, and every wrong turn produced
the same user-visible symptom: *"the screen bounces back"*.

What is drawn is always **stored view + however much of the live head leaks
through**:

| Mode | Head leak | What moves the stored part |
| --- | --- | --- |
| `mouse · locked view` | none, pinned at 0 | nothing |
| `mouse · panning view` | 1:1, tracks the head | edge push |
| `head · dragging view` | none | the head, past `headSlackDeg` |

The two halves answer *different questions*: the live head **reverses** when the
neck comes back, the stored part does not. So a position kept in the wrong half is
guaranteed to spring back, and no amount of tuning the mechanism that writes it can
help. The original code assembled `gaze + pan` at each point of use, with `pan` in
the session and a second held-view pair in the pointer, and that split is exactly
what made this hard to see. `VrView` now computes the direction in one place and
publishes it as `direction`; the painter and the cursor both read it and cannot
disagree.

Consequences worth keeping:

- **Head mode must not leak the head into the view at all.** Its whole value is
  that a position you look at is a position you keep. Slack is what makes that
  usable — inside it only the cursor moves, so relaxing your neck a few degrees
  costs nothing.
- **`foldHeadIntoStored` is what makes the mouse edge push survive.** Pushing an
  edge is done while *looking* that way, so most of the displacement is the 1:1
  leak. Measured on device: a stored −17.1° held 182 px of a 455 px displacement
  and the other 273 px sprang back with the neck — and because the head had already
  taken the view to its travel limit, the push had nothing left to add and quit
  early, reporting `fx=0.00` while the user shoved as hard as the desktop allowed.
- **Clamp the stored view to `viewLimitDeg`, never past it.** Travel the renderer
  will not honour is dead offset that has to be unwound before the picture moves
  again — the same phantom-offset trap the cursor avoids by storing its *clamped*
  position.
- **Do not reuse the mouse's edge-band trigger for the head.** It is geometrically
  dead there: sitting in the band of a content edge that still hides desktop needs
  the cursor to lead the view centre by nearly half a viewport (~380 px at the
  shipped defaults), and a head-driven cursor never leads it by more than the slack.
- **An aim-past-the-edge trigger for the head was tried and removed.** Feeding the
  stored view back into its own trigger is positive feedback: it ran away to the
  clamp and pinned there with the phone lying still, reporting a constant 43 px
  "overshoot" the pan itself had manufactured. The slack follower replaced it.
- **Pointer amplification (`headReach`) was removed.** It existed to reach a screen
  edge without craning the neck; dragging solves that better, and the amplification
  made the drag threshold unusable — at ~3× gain near the edge, one degree of head
  separated idle from full speed.

### Decisions that are easy to undo by accident

**Geometry is pure and shared.** The painter decides what you see, the pointer
decides where a click lands, and both derive from `vr_geometry`. When that maths
lived in two hand-copied places they drifted and the reticle ended up 32px from the
cursor.

**Gaze is a `ValueNotifier`, not part of a model the video drives.** The painter
must repaint at display rate when the head moves even while video arrives a few
frames a second. Coupling them makes head motion feel as laggy as the slowest
frame, which is the standard way to make a viewer queasy.

**Never pass an async function to `setState`.** `setState(() => vr.setMode(v))`
looks fine and is not: the arrow returns `setMode`'s `Future`, and `setState`
*throws* on a callback that returns one — after running it, before scheduling the
rebuild. The state changed and persisted while the widget never repainted, which
presented as "changing the mode in settings does nothing until you leave the page
and come back". Use a block body so the callback returns `void`. Note that
`setState(() => x = v)` is safe, because an assignment expression is not a Future,
so this only bites on calls.

**The host never echoes back a cursor we commanded.** `run_pos` in
`src/server/input_service.rs` sends `CursorPosition` with `send_without(exclude)`
where `exclude` is our own connection for 300 ms, then updates `cursor_pos`
unconditionally — so once that lapses `is_moved()` is already false and nothing is
sent. `CursorModel` stays at `-10000` all session. `VrCursor` tracks the position
itself and publishes it as a **fraction of the display**, because `FfiModel`
divides display lengths by `display.scale` for HiDPI peers, so subtracting the
origin alone misplaces the cursor on exactly those hosts.

**Head aim and the mouse are alternatives, never blended.** Trimming head aim with
the mouse was tried and reverted: mixing them leaves no way to say what is driving
the pointer. Every mode label therefore leads with the pointer source
(`mouse · panning view`), because a mode that silently ignores mouse movement
otherwise reads as a broken mouse — which is exactly how it got reported.

**The lens warp is one shader pass, and only the cursor follows it.** Radius is
normalised to the eye viewport's **half-diagonal** (so `r ≤ ~1.08` anywhere, and
`k2·r⁴` never swamps `k1·r²`, which is what lets the two be nulled independently),
and the polynomial is divided by **g(1) = 1+k1+k2** (pinning `r = 1` as a fixed
point, so `k1` reshapes without also zooming — `eyeFovDeg` already owns zoom).
Because `r = 1` is then the panel corner, the map takes the eye disc onto itself
and adds no black ring. The reticle is *not* warped and that is correct: it sits on
the optical axis, the fixed point, so it cannot move — which is why head-pointer
aiming survives for free. The cursor **is** warped, via `LensWarp.toPanel`.

Traps: **two `FragmentShader` instances, never one shared** — a `Picture` holds a
reference, not a snapshot, so sharing gives both eyes the second eye's lens centre
and reads as an IPD fault; **uniform indices are positional**, hence
`LensUniforms`; **`k2` must not go below −0.10** or the map is non-monotone before
the corner and the image folds inside out at the edge; **binding a shader drops
`Paint.filterQuality`** ([flutter#133944](https://github.com/flutter/flutter/issues/133944)),
hence the uniform-gated 4-tap; **published Cardboard profiles do not transfer**,
being in tan-angle units.

**Overscan is what lets a corner be looked at straight on.** Bounding the source
rect inside the desktop confines the view *centre* to the desktop eroded by half a
viewport. Clamping the centre instead trades empty space past the edge for corner
reach. Three places must agree: the follow-cursor nudge, the plain `drawImageRect`
path (undefined for a src outside its image — draw the intersection), and the
shader's bounds test, which must reject uv outside the **image**, not the source
rect, or the outer row of desktop smears across the overhang and slides as the head
pans.

**Full brightness is a correctness fix, not a preference.** A viewer covers the
ambient light sensor, so auto-brightness reads near-dark and dims the panel exactly
when the lenses are already absorbing much of the light. Applied as a *window*
override, so no permission is needed and Android drops it when the window goes
away.

### Upstream facts this depends on

- The **mobile** remote view paints each frame with `CustomPaint` over a
  `dart:ui.Image` (`ImageModel.image`), **not** a platform `Texture` — which is why
  stereo is two `drawImageRect` calls rather than a GL pipeline. Desktop uses a
  texture path; do not generalise from it.
- `InputModel.getPointInRemoteRect(isLocalDesktop: false, …)` returns **null** when
  *both* axes are out of range, so clamp before calling it if input can overshoot
  diagonally.
- `InputModel.scroll(int y)` is **vertical only**; an `AXIS_HSCROLL` value must be
  dropped, not forwarded.
- `tapDown`/`tapUp` carry **no coordinates** — they act wherever the host last put
  the cursor, so coalesced motion must be flushed before a button goes down.
- `moveMouse` and `sendMouse` both open with `if (!keyboardPerm) return;`, so
  without host input permission every move and click is dropped **in silence**.
  `VrCursor` logs that transition, because it is otherwise indistinguishable from
  a broken VR mode.

## In-headset controls

The screen is unreachable once the phone is in the viewer, so the middle button
doubles as a modifier.

| Input | Action |
| --- | --- |
| middle + left | next mode |
| middle + right | leave VR |
| hold middle | recentre |
| tap middle | ordinary middle click, forwarded |
| screen tap | left click at the cursor, hold to drag |
| back gesture | leave VR (escape hatch if the mouse fails) |

Three modes, named pointer-source first: `mouse · panning view`,
`head · dragging view`, `mouse · locked view`.

Calibration is reachable two ways, both working with nothing connected: **Settings
→ Cardboard VR**, or the tune button beside the VR button in a session. The
in-headset walk-through is head-driven: turn to set a value, tap or click for the
next.

## Verification status

Builds clean; `flutter analyze` is clean for the files above; the shader compiles
to an IPLR and ships in the APK.

**Confirmed on hardware** across two devices — Pixel 7 / Android 17, and Pixel
"sailfish" / Android 10, which also exercises the GLES renderer rather than
Impeller: installs alongside official RustDesk, `librustdesk.so` loads, pointer
capture engages and captured mouse movement and clicks work, after the two fixes
above. Both `LensWarp` directions were checked numerically: worst round-trip error
2.8e-3 px, `ideal(1) == 1.000000` exactly, monotone to the far corner.

Confirmed by the user on the dev Pixel, and the reason the view model looks the way
it does:

- **head mode drags and stays put** — the behaviour the mode exists for;
- **the mouse edge push moves the view and the move persists**;
- **the mode radio repaints on first tap** (the `setState`-returning-a-Future bug).

The user's verdict on the mouse modes was "not what I originally wanted, but
acceptable" — they wanted the head to do the pushing, which is what head mode now
is. Do not treat the mouse edge push as the primary way to move the view.

**Still unverified**, because it needs the viewer:

- The **sign** of yaw/pitch panning and of scroll. If panning goes the wrong way,
  flip it in `sourceRect` and in `VrView`'s drag together, or the reticle and cursor
  diverge.
- Whether the defaults fuse into a comfortable image, and whether `k1 ≈ 0.22`
  straightens a real viewer's lenses. Note the user runs `screenWidth=120°`,
  `ipd=0px`, `k1≈0.20`, `k2=-0.10` — two of those are at a range end, and `k2` is at
  its floor, so the shipped defaults are not what has been looked through.
- Whether a Cardboard lever registers reliably for tap-to-click, and whether the
  viewer's foam causes phantom clicks (remedy: the "Screen tap clicks" switch).
- Whether the phone's rotation sensor drifts enough to matter. One log showed the
  view sliding ~300 px over 7 s with the stored view at zero; that was never pinned
  down as drift versus real head movement, and recentre is the remedy either way.

### Working on this with hardware in the loop

Two process notes that were learned expensively, both about not fooling yourself.

**Put the diagnostic ahead of the guards.** A probe placed after the early returns
can only report the path you already assumed was taken. One round was spent
confirming an assumption instead of testing it.

**Check the mode and the mouse before believing a behaviour report.** Two separate
"still not working" rounds were a persisted mode that disables the feature under
test, and a Bluetooth mouse that had gone to sleep (`DISCONNECTED … reason=19` in
`dumpsys bluetooth_manager`). Both look exactly like a broken feature. `[vr]
prepare` logs the mode on every entry and `[vr] mode ->` logs every switch, so read
those first.
