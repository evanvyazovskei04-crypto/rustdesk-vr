#version 460 core

// Barrel pre-warp cancelling a Cardboard-class viewer's pincushion.
//
// Deliberately "#version 460 core" and not an "es" profile. impellerc
// cross-compiles this to a #version 100 GLES stage, and a desktop-GLSL source
// makes every uniform come out highp there. Under an es profile the default is
// mediump, and fp16 is only exact on integers to 2048 while canvas x reaches
// ~914 logical / 2400 device px.
#include <flutter/runtime_effect.glsl>

// Declaration order IS the Dart setFloat index order; samplers are indexed
// separately from 0 and consume no float slot. No vec3 anywhere -- Impeller pads
// those to vec4 and silently shifts every index after.
uniform vec2 uLensCentre;  //  0,1   optical axis, canvas logical px
uniform vec2 uK;           //  2,3   k1, k2
uniform vec2 uNorm;        //  4,5   1/rNorm, 1/(1 + k1 + k2)
uniform vec4 uDst;         //  6..9  ideal image rect: l, t, w, h
uniform vec4 uSrcUv;       // 10..13 source rect, already normalised: u,v,du,dv
uniform vec2 uTexel;       // 14,15  1 / frame size
uniform vec2 uOpts;        // 16,17  x: manual bilinear, y: grid pitch (0 = off)

uniform sampler2D uFrame;  // sampler 0

out vec4 fragColor;

// The 4-tap path exists because setImageSampler takes no sampling options, so
// Paint.filterQuality stops applying the moment a shader is bound. Whether the
// backend's own sampler filters cannot be checked off-device, and the tell
// (stair-stepped window borders while holding still) is only visible on a
// phone. A uniform-gated fallback makes that a switch rather than a rebuild.
vec4 tap(vec2 uv) {
  if (uOpts.x < 0.5) {
    return texture(uFrame, uv);
  }
  vec2 tc = uv / uTexel - 0.5;
  vec2 b = floor(tc);
  vec2 f = tc - b;
  vec2 o = (b + 0.5) * uTexel;
  vec4 c00 = texture(uFrame, o);
  vec4 c10 = texture(uFrame, o + vec2(uTexel.x, 0.0));
  vec4 c01 = texture(uFrame, o + vec2(0.0, uTexel.y));
  vec4 c11 = texture(uFrame, o + uTexel);
  return mix(mix(c00, c10, f.x), mix(c01, c11, f.x), f.y);
}

void main() {
  // FlutterFragCoord is canvas-LOCAL logical px. A CustomPainter canvas carries
  // no extra transform, so uLensCentre is passed in the painter's own
  // coordinates with no devicePixelRatio factor.
  vec2 d = FlutterFragCoord().xy - uLensCentre;

  // Even in r, so it evaluates on r^2 and needs no sqrt; d already carries the
  // direction. One scalar normalisation, never per-axis: dividing x and y by
  // different numbers makes r elliptical, which no radially symmetric lens is,
  // and then no single k1 can straighten both horizontals and verticals.
  float r2 = dot(d, d) * uNorm.x * uNorm.x;

  // r_ideal = r * (1 + k1 r^2 + k2 r^4) / (1 + k1 + k2).
  //
  // Dividing by g(1) pins r = 1 -- which with half-diagonal normalisation is the
  // panel CORNER -- as an exact fixed point. Two consequences, both the reason
  // for this parametrisation:
  //   * k1 reshapes without also zooming, so it can be nulled by eye against
  //     eyeFovDeg, which already owns zoom.
  //   * r_ideal <= r everywhere inside the corner, so the warp introduces no
  //     black ring -- only the two outer corners overshoot slightly, because the
  //     IPD shift pushes them past r = 1.
  vec2 u = uLensCentre + d * ((1.0 + r2 * (uK.x + r2 * uK.y)) * uNorm.y);

  // Rectilinear grid laid out in IDEAL space about the lens axis, so "are the
  // lines straight through the lens" is the entire judgement. Procedural: no
  // asset, no second draw, and it travels through exactly the same warp the
  // desktop does.
  if (uOpts.y > 0.0) {
    vec2 q = abs(fract((u - uLensCentre) / uOpts.y + 0.5) - 0.5) * uOpts.y;
    float a = 1.0 - smoothstep(0.6, 1.6, min(q.x, q.y));
    fragColor = vec4(a * 0.85);   // premultiplied white
    return;
  }

  vec2 t = (u - uDst.xy) / uDst.zw;
  if (any(lessThan(t, vec2(0.0))) || any(greaterThan(t, vec2(1.0)))) {
    // Transparent black outside the source rect -- never clamped, never wrapped.
    // The bound that matters is the gaze-dependent SOURCE RECT, not the image,
    // and setImageSampler takes no tile mode, so this test cannot be delegated.
    // Clamping would smear the outermost row of desktop pixels radially into the
    // far periphery, where the smear slides as the head pans; peripheral motion
    // that does not match real world-motion is a nausea source, not just an ugly
    // edge. Wrapping is worse: the two eyes would wrap different content, which
    // is binocular rivalry.
    fragColor = vec4(0.0);
    return;
  }

  vec2 uv = uSrcUv.xy + t * uSrcUv.zw;

  // With overscan the source rect deliberately hangs off the desktop so a corner
  // can be brought under the reticle, which means uv can land outside the image
  // itself. That has to read as empty, not as smeared edge pixels: setImageSampler
  // takes no tile mode, so clamping here is the only thing standing between the
  // user and the outermost row of desktop stretched across the whole overhang --
  // and because the overhang slides as the head pans, the smear would slide with
  // it. Peripheral motion that does not match real world-motion is a nausea
  // source, not merely an ugly edge.
  if (any(lessThan(uv, vec2(0.0))) || any(greaterThan(uv, vec2(1.0)))) {
    fragColor = vec4(0.0);
    return;
  }

  // Half a texel in from the IMAGE bound, so a bilinear tap at the very edge
  // cannot reach past it and pull in whatever the sampler decides lives there.
  fragColor = tap(clamp(uv, uTexel * 0.5, vec2(1.0) - uTexel * 0.5));
}
