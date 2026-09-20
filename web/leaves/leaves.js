// Leaves — opaque foliage framing the screen, hovering motes of light, and a
// slow firelight pulse warming whatever the light reaches.
//
// Drawing order is what sells the depth: ambient firelight glow, then the three
// leaf layers back to front, with motes slotted between them so some of them
// drift behind foliage.

(function () {
  'use strict';

  var canvas = document.getElementById('scene');
  var ctx = canvas.getContext('2d', { alpha: true });
  var fpsEl = document.getElementById('fps');

  var W = 0, H = 0, DPR = 1;
  var branches = [];
  var motes = [];
  var strays = [];
  var palettes = [];
  var moteSprite = null;

  // Leaves are shadows: firelight lifts them within a black -> green range and
  // never towards orange. The fire's own colour lives in the ambient pools and
  // the motes, not on the foliage.
  var LIT = [56, 110, 62];
  var SEED = 20260920;           // fixed, so live-reloading does not reshuffle the set

  // Back to front. Nearer foliage is bigger, darker and sways more; the distant
  // layer stays a lighter, hazier green.
  // tintMax caps how far firelight can pull a leaf towards orange. Leaving it
  // uncapped turns the whole canopy autumnal; these stay green and black, warmed.
  var LAYERS = [
    { base: [34, 68, 40], jitter: 14, scale: 0.62, leafScale: 0.85, density: 0.85, sway: 0.018, swaySpeed: 0.21, light: 0.50, tintMax: 0.45, rib: true  },
    { base: [16, 38, 22], jitter: 10, scale: 0.85, leafScale: 1.10, density: 0.70, sway: 0.025, swaySpeed: 0.29, light: 0.80, tintMax: 0.38, rib: true  },
    { base: [ 9, 18, 12], jitter:  5, scale: 1.15, leafScale: 1.45, density: 0.55, sway: 0.034, swaySpeed: 0.37, light: 1.00, tintMax: 0.26, rib: false }
  ];

  // Anchors live just off-screen and grow inward, so foliage reads as intruding
  // into frame. The middle band is deliberately sparse — that is where the
  // terminals need to stay readable.
  // Four corner clusters, anchored just off-frame and growing diagonally in.
  // Nothing along the edges or the top centre: the middle of the screen is
  // where the work being projected has to stay readable.
  // Four corner clusters, anchored just off-frame and growing diagonally in.
  // Nothing along the edges or the top centre: the middle of the screen is
  // where the work being projected has to stay readable.
  // Three short stubs per corner, anchored just off-frame and growing
  // diagonally in. Nothing along the edges or the top centre: the middle of the
  // screen is where the work being projected has to stay readable.
  var ANCHORS = [
    { x: -0.08, y: -0.05, a:   38, len: 0.26 },   // top left
    { x: -0.01, y: -0.11, a:   58, len: 0.22 },
    { x: -0.12, y:  0.08, a:   20, len: 0.19 },
    { x:  1.08, y: -0.05, a:  142, len: 0.26 },   // top right
    { x:  1.01, y: -0.11, a:  122, len: 0.22 },
    { x:  1.12, y:  0.08, a:  160, len: 0.19 },
    { x: -0.08, y:  1.05, a:  -38, len: 0.24 },   // bottom left
    { x: -0.01, y:  1.11, a:  -58, len: 0.21 },
    { x: -0.12, y:  0.92, a:  -20, len: 0.18 },
    { x:  1.08, y:  1.05, a: -142, len: 0.24 },   // bottom right
    { x:  1.01, y:  1.11, a: -122, len: 0.21 },
    { x:  1.12, y:  0.92, a: -160, len: 0.18 }
  ];

  // Off-frame fire sources. Each breathes on its own slow cycle.
  var LIGHTS = [
    { fx: 0.50, fy: 1.26, fr: 0.62, base: 1.05, speed: 0.38, phase: 0.0, now: 0, x: 0, y: 0, r: 0 },
    { fx: 0.11, fy: 1.10, fr: 0.38, base: 0.55, speed: 0.61, phase: 2.2, now: 0, x: 0, y: 0, r: 0 }
  ];

  // mulberry32 — deterministic, so the composition is stable and tunable.
  function rng(seed) {
    return function () {
      seed = seed + 0x6D2B79F5 | 0;
      var t = Math.imul(seed ^ seed >>> 15, 1 | seed);
      t = t + Math.imul(t ^ t >>> 7, 61 | t) ^ t;
      return ((t ^ t >>> 14) >>> 0) / 4294967296;
    };
  }

  // ---- colour cache -------------------------------------------------------
  // Leaves are re-tinted every frame as the fire pulses. Quantising the amount
  // and caching the strings keeps this from allocating thousands of them a
  // second.
  var TINT_STEPS = 18;

  function buildPalette(layer, rnd) {
    var variants = [];
    for (var v = 0; v < 6; v++) {
      var j = (rnd() - 0.5) * 2 * layer.jitter;
      var rgb = [
        clamp255(layer.base[0] + j * 0.8),
        clamp255(layer.base[1] + j),
        clamp255(layer.base[2] + j * 0.7)
      ];
      var steps = [];
      for (var s = 0; s <= TINT_STEPS; s++) {
        var amt = s / TINT_STEPS;
        steps.push('rgb(' +
          Math.round(rgb[0] + (LIT[0] - rgb[0]) * amt) + ',' +
          Math.round(rgb[1] + (LIT[1] - rgb[1]) * amt) + ',' +
          Math.round(rgb[2] + (LIT[2] - rgb[2]) * amt) + ')');
      }
      variants.push(steps);
    }
    return variants;
  }

  function clamp255(v) { return v < 0 ? 0 : v > 255 ? 255 : v; }

  // ---- construction -------------------------------------------------------

  function buildBranch(spec, layer, palette, rnd) {
    var len = spec.len * Math.min(W, H) * layer.scale;
    var curve = (rnd() - 0.5) * 0.85;
    var count = 4 + Math.floor(rnd() * 4);
    var unit = Math.min(W, H) * layer.leafScale;
    var leaves = [];

    for (var i = 0; i < count; i++) {
      var t = 0.14 + (i / count) * 0.86;
      var side = (i % 2 === 0) ? 1 : -1;
      leaves.push({
        t: t,
        size: (0.095 + rnd() * 0.075) * unit * (1.05 - t * 0.35),
        width: 0.24 + rnd() * 0.12,
        angle: side * (0.45 + rnd() * 0.55),
        flutter: rnd() * Math.PI * 2,
        flutterRate: 0.5 + rnd() * 0.9,
        palette: palette[Math.floor(rnd() * palette.length)]
      });
    }

    return {
      x: spec.x * W,
      y: spec.y * H,
      angle: spec.a * Math.PI / 180 + (rnd() - 0.5) * 0.28,
      len: len,
      c1x: len * 0.5, c1y: curve * len * 0.30,
      c2x: len,       c2y: curve * len * 0.85,
      stemWidth: Math.max(1.5, len * 0.012),
      stemColor: 'rgb(' + Math.round(layer.base[0] * 0.75) + ',' +
                          Math.round(layer.base[1] * 0.75) + ',' +
                          Math.round(layer.base[2] * 0.75) + ')',
      phase: rnd() * Math.PI * 2,
      layer: layer,
      leaves: leaves
    };
  }

  // Biased outwards, but a few are allowed to wander into the open.
  function strayPos(rnd) {
    var x = rnd(), y = rnd();
    if (rnd() < 0.65) {
      if (rnd() < 0.5) x = rnd() < 0.5 ? rnd() * 0.28 : 0.72 + rnd() * 0.28;
      else             y = rnd() < 0.5 ? rnd() * 0.26 : 0.74 + rnd() * 0.26;
    }
    return { x: x, y: y };
  }

  function makeStray(rnd) {
    var pos = strayPos(rnd);
    return {
      x: pos.x,
      y: pos.y,
      size: (0.055 + rnd() * 0.045) * Math.min(W, H),
      width: 0.24 + rnd() * 0.12,
      angle: rnd() * 6.283,
      spin: 0.05 + rnd() * 0.10,
      bobR: 3 + rnd() * 9,
      bobF: 0.07 + rnd() * 0.16,
      bobP: rnd() * 6.283,
      rib: rnd() < 0.5,
      palette: palettes[Math.floor(rnd() * palettes.length)]
    };
  }

  function makeMote(rnd) {
    return {
      hx: rnd(),
      hy: 0.12 + rnd() * 0.78,
      r1: 18 + rnd() * 70,               // hover radii, two axes at two rates
      r2: 10 + rnd() * 45,
      f1: 0.10 + rnd() * 0.22,
      f2: 0.16 + rnd() * 0.34,
      p1: rnd() * 6.283,
      p2: rnd() * 6.283,
      dx: (rnd() - 0.5) * 0.010,         // slow drift across the frame
      dy: (rnd() - 0.5) * 0.005,
      size: 16 + rnd() * 26,
      period: 2.4 + rnd() * 4.0,
      phase: rnd() * 6.283,
      behind: rnd() < 0.45               // drawn before the near foliage
    };
  }

  function buildMoteSprite() {
    var size = 64, c = document.createElement('canvas');
    c.width = c.height = size;
    var g = c.getContext('2d');
    var grad = g.createRadialGradient(size / 2, size / 2, 0, size / 2, size / 2, size / 2);
    grad.addColorStop(0.00, 'rgba(255, 252, 214, 0.95)');
    grad.addColorStop(0.18, 'rgba(226, 255, 168, 0.55)');
    grad.addColorStop(0.45, 'rgba(150, 220, 110, 0.16)');
    grad.addColorStop(1.00, 'rgba(120, 200, 90, 0)');
    g.fillStyle = grad;
    g.fillRect(0, 0, size, size);
    return c;
  }

  function rebuild() {
    var rnd = rng(SEED);
    branches = [];
    palettes = [];

    for (var li = 0; li < LAYERS.length; li++) {
      var layer = LAYERS[li];
      var palette = buildPalette(layer, rnd);
      if (li > 0) palettes.push(palette[0]);
      for (var ai = 0; ai < ANCHORS.length; ai++) {
        if (rnd() > layer.density) continue;
        var spec = ANCHORS[ai];
        branches.push(buildBranch({
          x: spec.x + (rnd() - 0.5) * 0.05,
          y: spec.y + (rnd() - 0.5) * 0.04,
          a: spec.a + (rnd() - 0.5) * 16,
          len: spec.len * (0.85 + rnd() * 0.3)
        }, layer, palette, rnd));
      }
    }

    strays = [];
    for (var s = 0; s < 8; s++) strays.push(makeStray(rnd));

    motes = [];
    for (var m = 0; m < 30; m++) motes.push(makeMote(rnd));
  }

  // ---- lighting -----------------------------------------------------------

  function updateLights(t) {
    for (var i = 0; i < LIGHTS.length; i++) {
      var l = LIGHTS[i];
      var breath = 0.70 + 0.30 * Math.sin(t * l.speed + l.phase);
      // A little incoherent flicker on top of the slow breath.
      var flicker = 1 + 0.05 * Math.sin(t * 6.1 + l.phase * 3) * Math.sin(t * 11.3 + l.phase);
      l.now = l.base * breath * flicker;
      l.x = l.fx * W;
      l.y = l.fy * H;
      l.r = l.fr * Math.max(W, H);
    }
  }

  function lightAt(x, y) {
    var v = 0;
    for (var i = 0; i < LIGHTS.length; i++) {
      var l = LIGHTS[i];
      var dx = (x - l.x) / l.r, dy = (y - l.y) / l.r;
      v += l.now / (1 + (dx * dx + dy * dy) * 4.2);
    }
    return v;
  }

  // ---- drawing ------------------------------------------------------------

  function leafPath(len, wid) {
    var stalk = len * 0.15;
    var L = len - stalk;
    var w = L * wid;
    ctx.beginPath();
    ctx.moveTo(stalk, 0);
    ctx.bezierCurveTo(stalk + L * 0.16, w, stalk + L * 0.60, w * 0.82, len, 0);
    ctx.bezierCurveTo(stalk + L * 0.60, -w * 0.82, stalk + L * 0.16, -w, stalk, 0);
    ctx.closePath();
  }

  // A bare blade reads as a pebble; the stalk and midrib are what make it a leaf.
  function drawLeaf(len, wid, color, rib, rim) {
    ctx.fillStyle = color;
    leafPath(len, wid);
    ctx.fill();

    if (rim > 0.02) {
      ctx.strokeStyle = 'rgba(255, 150, 62, ' + rim.toFixed(3) + ')';
      ctx.lineWidth = Math.max(1, len * 0.016);
      ctx.stroke();              // the blade path is still current after fill()
    }

    ctx.strokeStyle = color;
    ctx.lineWidth = Math.max(1, len * 0.035);
    ctx.beginPath();
    ctx.moveTo(0, 0);
    ctx.lineTo(len * 0.16, 0);
    ctx.stroke();

    if (rib) {
      ctx.strokeStyle = 'rgba(0, 0, 0, 0.22)';
      ctx.lineWidth = Math.max(0.6, len * 0.018);
      ctx.beginPath();
      ctx.moveTo(len * 0.15, 0);
      ctx.lineTo(len * 0.92, 0);
      ctx.stroke();
    }
  }

  function quadPoint(b, t) {
    var mt = 1 - t;
    return {
      x: 2 * mt * t * b.c1x + t * t * b.c2x,
      y: 2 * mt * t * b.c1y + t * t * b.c2y,
      // derivative, for the leaf's attachment angle
      ax: 2 * mt * b.c1x + 2 * t * (b.c2x - b.c1x),
      ay: 2 * mt * b.c1y + 2 * t * (b.c2y - b.c1y)
    };
  }

  function drawBranch(b, t) {
    var rot = b.angle + Math.sin(t * b.layer.swaySpeed + b.phase) * b.layer.sway;
    var ca = Math.cos(rot), sa = Math.sin(rot);

    ctx.save();
    ctx.translate(b.x, b.y);
    ctx.rotate(rot);

    ctx.beginPath();
    ctx.moveTo(0, 0);
    ctx.quadraticCurveTo(b.c1x, b.c1y, b.c2x, b.c2y);
    ctx.lineWidth = b.stemWidth;
    ctx.lineCap = 'round';
    ctx.strokeStyle = b.stemColor;
    ctx.stroke();

    for (var i = 0; i < b.leaves.length; i++) {
      var leaf = b.leaves[i];
      var p = quadPoint(b, leaf.t);

      // World position, so the leaf can ask how much firelight reaches it.
      var wx = b.x + p.x * ca - p.y * sa;
      var wy = b.y + p.x * sa + p.y * ca;
      var lit = 1 - Math.exp(-lightAt(wx, wy) * b.layer.light * 1.25);
      var step = (lit * b.layer.tintMax * TINT_STEPS) | 0;
      if (step > TINT_STEPS) step = TINT_STEPS;

      ctx.save();
      ctx.translate(p.x, p.y);
      ctx.rotate(Math.atan2(p.ay, p.ax) + leaf.angle +
                 Math.sin(t * leaf.flutterRate + leaf.flutter) * 0.07);
      drawLeaf(leaf.size, leaf.width, leaf.palette[step], b.layer.rib, lit * 0.60);
      ctx.restore();
    }

    ctx.restore();
  }

  function drawMotes(t, behind) {
    for (var i = 0; i < motes.length; i++) {
      var m = motes[i];
      if (m.behind !== behind) continue;

      var hx = ((m.hx + m.dx * t) % 1.1 + 1.1) % 1.1 - 0.05;
      var hy = ((m.hy + m.dy * t) % 1.0 + 1.0) % 1.0;
      var x = hx * W + Math.sin(t * m.f1 * 6.283 + m.p1) * m.r1;
      var y = hy * H + Math.cos(t * m.f2 * 6.283 + m.p2) * m.r2;

      // Sharp flare, long dark gap: reads as a firefly rather than a star.
      var s = Math.sin(t * 6.283 / m.period + m.phase);
      var a = (s > 0 ? Math.pow(s, 5) : 0) * 0.9 + 0.05;
      var size = m.size * (0.7 + a * 0.5);

      ctx.globalAlpha = a;
      ctx.drawImage(moteSprite, x - size / 2, y - size / 2, size, size);
    }
    ctx.globalAlpha = 1;
  }

  function drawStrays(t) {
    for (var i = 0; i < strays.length; i++) {
      var s = strays[i];
      var x = s.x * W;
      var y = s.y * H + Math.sin(t * s.bobF * 6.283 + s.bobP) * s.bobR;
      var lit = 1 - Math.exp(-lightAt(x, y) * 0.8 * 1.25);
      var step = (lit * 0.34 * TINT_STEPS) | 0;

      ctx.save();
      ctx.translate(x, y);
      ctx.rotate(s.angle + Math.sin(t * s.bobF * 4.1 + s.bobP) * s.spin);
      drawLeaf(s.size, s.width, s.palette[step], s.rib, lit * 0.52);
      ctx.restore();
    }
  }

  function drawAmbient() {
    for (var i = 0; i < LIGHTS.length; i++) {
      var l = LIGHTS[i];
      var g = ctx.createRadialGradient(l.x, l.y, 0, l.x, l.y, l.r);
      g.addColorStop(0, 'rgba(255, 138, 48, ' + (0.16 * l.now).toFixed(3) + ')');
      g.addColorStop(1, 'rgba(255, 120, 40, 0)');
      ctx.fillStyle = g;
      ctx.fillRect(0, 0, W, H);
    }
  }

  // ---- loop ---------------------------------------------------------------

  function resize() {
    DPR = window.devicePixelRatio || 1;
    W = window.innerWidth;
    H = window.innerHeight;
    canvas.width = Math.round(W * DPR);
    canvas.height = Math.round(H * DPR);
    canvas.style.width = W + 'px';
    canvas.style.height = H + 'px';
    ctx.setTransform(DPR, 0, 0, DPR, 0, 0);
    rebuild();
  }

  var fpsFrames = 0, fpsSince = performance.now();

  function frame(now) {
    var t = now / 1000;

    ctx.clearRect(0, 0, W, H);
    updateLights(t);
    drawAmbient();

    // back layer, distant motes, mid layer, near motes, near layer
    var i;
    for (i = 0; i < branches.length; i++) {
      if (branches[i].layer === LAYERS[0]) drawBranch(branches[i], t);
    }
    drawMotes(t, true);
    for (i = 0; i < branches.length; i++) {
      if (branches[i].layer === LAYERS[1]) drawBranch(branches[i], t);
    }
    drawStrays(t);
    drawMotes(t, false);
    for (i = 0; i < branches.length; i++) {
      if (branches[i].layer === LAYERS[2]) drawBranch(branches[i], t);
    }

    fpsFrames++;
    if (now - fpsSince >= 500) {
      fpsEl.textContent = Math.round(fpsFrames * 1000 / (now - fpsSince)) + ' fps';
      fpsFrames = 0;
      fpsSince = now;
    }

    requestAnimationFrame(frame);
  }

  moteSprite = buildMoteSprite();
  resize();
  window.addEventListener('resize', resize);
  requestAnimationFrame(frame);
})();
