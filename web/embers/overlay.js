// Overlay demo content. Plain classic script on purpose: loaded over file://,
// ES modules would be blocked by CORS. Point the app at a dev server with
// --url if you want modules or fetch().

(function () {
  'use strict';

  var INSET = 0;                // read from --inset in overlay.css by resize()
  var RUNNER_SPEED = 460;       // px per second along the perimeter
  var EMBER_COUNT = 90;

  var canvas = document.getElementById('embers');
  var ctx = canvas.getContext('2d', { alpha: true });
  var runner = document.querySelector('.runner');
  var fpsEl = document.getElementById('fps');
  var dimsEl = document.getElementById('dims');

  var w = 0, h = 0, dpr = 1;
  var embers = [];
  var sprite = null;

  // Pre-rendered glow. Far cheaper than ctx.shadowBlur per particle, which
  // matters when this is compositing over the whole projected desktop.
  function buildSprite() {
    var size = 64;
    var c = document.createElement('canvas');
    c.width = c.height = size;
    var g = c.getContext('2d');
    var grad = g.createRadialGradient(size / 2, size / 2, 0, size / 2, size / 2, size / 2);
    grad.addColorStop(0.0, 'rgba(255, 214, 150, 0.95)');
    grad.addColorStop(0.25, 'rgba(255, 160, 60, 0.45)');
    grad.addColorStop(1.0, 'rgba(255, 120, 30, 0)');
    g.fillStyle = grad;
    g.fillRect(0, 0, size, size);
    return c;
  }

  function spawn(atBottom) {
    return {
      x: Math.random() * w,
      y: atBottom ? h + Math.random() * 80 : Math.random() * h,
      vy: -(8 + Math.random() * 26),          // px per second, upward
      vx: (Math.random() - 0.5) * 12,
      size: 4 + Math.random() * 18,
      alpha: 0.12 + Math.random() * 0.4,
      drift: Math.random() * Math.PI * 2,
      wobble: 0.4 + Math.random() * 1.1
    };
  }

  function resize() {
    // Single source of truth: the CSS variable.
    INSET = parseFloat(getComputedStyle(document.documentElement)
                       .getPropertyValue("--inset")) || 0;

    dpr = window.devicePixelRatio || 1;
    w = window.innerWidth;
    h = window.innerHeight;
    canvas.width = Math.round(w * dpr);
    canvas.height = Math.round(h * dpr);
    canvas.style.width = w + 'px';
    canvas.style.height = h + 'px';
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);

    embers = [];
    for (var i = 0; i < EMBER_COUNT; i++) embers.push(spawn(false));

    dimsEl.textContent = w + '×' + h + ' @' + dpr + 'x';
  }

  // Walk the inset rectangle's perimeter and report where we are on it.
  function perimeterPoint(dist) {
    var iw = Math.max(1, w - INSET * 2);
    var ih = Math.max(1, h - INSET * 2);
    var d = ((dist % (2 * (iw + ih))) + 2 * (iw + ih)) % (2 * (iw + ih));

    if (d < iw) return { x: INSET + d, y: INSET, rot: 0 };
    d -= iw;
    if (d < ih) return { x: w - INSET, y: INSET + d, rot: 90 };
    d -= ih;
    if (d < iw) return { x: w - INSET - d, y: h - INSET, rot: 180 };
    d -= iw;
    return { x: INSET, y: h - INSET - d, rot: 270 };
  }

  var lastFrame = performance.now();
  var fpsFrames = 0;
  var fpsSince = lastFrame;

  function frame(now) {
    var dt = Math.min((now - lastFrame) / 1000, 0.1);   // clamp after a stall
    lastFrame = now;

    // --- embers ---
    ctx.clearRect(0, 0, w, h);
    for (var i = 0; i < embers.length; i++) {
      var e = embers[i];
      e.drift += dt * e.wobble;
      e.y += e.vy * dt;
      e.x += (e.vx + Math.sin(e.drift) * 9) * dt;

      if (e.y + e.size < 0) embers[i] = spawn(true);

      ctx.globalAlpha = e.alpha;
      ctx.drawImage(sprite, e.x - e.size / 2, e.y - e.size / 2, e.size, e.size);
    }
    ctx.globalAlpha = 1;

    // --- perimeter runner ---
    var p = perimeterPoint(now / 1000 * RUNNER_SPEED);
    runner.style.transform =
      'translate(' + p.x + 'px, ' + p.y + 'px) rotate(' + p.rot + 'deg) translate(-50%, -50%)';

    // --- readout ---
    fpsFrames++;
    if (now - fpsSince >= 500) {
      fpsEl.textContent = Math.round(fpsFrames * 1000 / (now - fpsSince)) + ' fps';
      fpsFrames = 0;
      fpsSince = now;
    }

    requestAnimationFrame(frame);
  }

  sprite = buildSprite();
  resize();
  window.addEventListener('resize', resize);
  requestAnimationFrame(frame);
})();
