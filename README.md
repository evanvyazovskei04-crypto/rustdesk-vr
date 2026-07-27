# RustDesk VR

View a remote desktop through a Google Cardboard viewer, on Android, and drive it
with a Bluetooth mouse or with your head.

A fork of [RustDesk](https://github.com/rustdesk/rustdesk) at tag **1.4.9** that
adds a stereoscopic VR mode to the Android client. Everything else about RustDesk
is untouched — same connection model, same UI, same self-hosting. The VR layer is
Dart and Kotlin only; the Rust core is not modified.

Not affiliated with or endorsed by the RustDesk project. It installs **alongside**
official RustDesk under its own application id, so it has its own RustDesk ID,
settings and peer list.

## What it does

A toolbar button in a remote session switches to side-by-side stereo. From there
the phone goes in the viewer, and everything is driven by head movement, a mouse,
or a tap on the panel.

**Three modes**, cycled in the headset with middle + left click. Each is named for
what moves the cursor and what the view does:

| Mode | Cursor | View |
| --- | --- | --- |
| `mouse · panning view` | Bluetooth mouse | tracks your head across a virtual screen wider than the lenses |
| `head · dragging view` | your head, aimed with the centre reticle | your head **drags** it, and it stays where you leave it |
| `mouse · locked view` | Bluetooth mouse | fixed in front of your face — immune to gyro drift |

`head · dragging view` is the one a bare Cardboard viewer can use with no mouse at
all: the conductive lever tapping the panel is a left click, and holding it drags.
The view follows your head through a few degrees of slack and then holds position,
so relaxing your neck doesn't throw the desktop back where it came from.

**Also included**

- **Barrel lens correction** as a single shader pass, with an in-headset
  calibration grid. Off by default — the coefficients belong to one specific piece
  of plastic, and a wrong correction looks worse than none.
- **In-headset calibration.** Tuning a viewer by dragging sliders means taking the
  headset off, which is the one thing that makes the result unjudgeable. Instead:
  turn your head to set a value, tap or click for the next. Works with nothing
  connected, since what it tunes belongs to the viewer rather than to any remote
  machine.
- **Reach the corners.** The view can travel until a corner of the desktop sits
  dead ahead, instead of being confined so the corners stay permanently off to the
  side at every head angle.
- **Full brightness in VR.** A viewer covers the ambient light sensor, so
  auto-brightness reads darkness and dims the panel exactly when the lenses are
  already absorbing much of the light. Applied as a window override: no permission
  needed, your system setting untouched.

## In-headset controls

The screen is unreachable once the phone is in the viewer, so the middle mouse
button doubles as a modifier.

| Input | Action |
| --- | --- |
| middle + left | next mode |
| middle + right | leave VR |
| hold middle | recentre — view straight ahead, forget any drag |
| tap middle | ordinary middle click, forwarded |
| screen tap | left click at the cursor, hold to drag |
| back gesture | leave VR (escape hatch if the mouse fails) |

Calibration is reachable two ways, both working with nothing connected: **Settings
→ Cardboard VR**, or the tune button beside the VR button in a session.

## Building

**The Rust core is not compiled here.** `librustdesk.so` is lifted out of the
matching official release APK, which removes the Android NDK, vcpkg and cargo-ndk
from the build entirely. arm64 only.

Needs **Flutter 3.24.5** exactly (what upstream CI pins — newer Dart rejects this
pubspec) and **JDK 17** (the Gradle wrapper is 7.6.4, predating Java 21 support).

```bash
source scripts/dev_env.sh
```

First-time setup, in this order — `pub get` must precede the bridge codegen or its
ffigen step dies on a missing `.dart_tool/package_config.json`:

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

`cargo fetch` and the submodule are prerequisites even though no Rust is built:
Gradle shells out to `cargo metadata` at configuration time to locate
`rustls-platform-verifier`'s Android Maven directory.

[CLAUDE.md](CLAUDE.md) has the rest — every pin, every trap, and the reasoning
behind the VR layer's design. Worth reading before changing anything under
`flutter/lib/mobile/vr/`.

## Status

Working and in use, with the honest caveat that one person has tested it on two
phones.

**Verified on hardware** — Pixel 7 (Android 17) and a Pixel "sailfish" (Android
10, which exercises the GLES renderer rather than Impeller):

- installs and runs alongside official RustDesk
- pointer capture engages, and captured mouse movement and clicks reach the host
- head dragging moves the desktop, and the position persists when you look back
- mouse edge-push pans the view, and that pan persists too

**Not yet verified**, because it needs a viewer rather than a phone on a desk:

- the **sign** of yaw/pitch panning and of scroll
- whether the shipped defaults fuse into a comfortable image, and whether
  `k1 ≈ 0.22` straightens a real viewer's lenses
- whether a Cardboard lever registers reliably for tap-to-click, and whether the
  viewer's foam causes phantom clicks (remedy: the "Screen tap clicks" switch)
- whether the phone's rotation sensor drifts enough to be a nuisance over a long
  session (remedy: recentre)

## Licence

[AGPL-3.0](LICENCE), inherited from RustDesk. All credit for RustDesk itself goes
to [the RustDesk project and its contributors](https://github.com/rustdesk/rustdesk);
this fork only adds the Android VR layer.
