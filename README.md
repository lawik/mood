# Overlay

A transparent, click-through web layer pinned above everything else on macOS.
Built for stage use: the projected desktop stays fully usable — terminals,
editors, whatever — while this draws set dressing on top of it.

    ./build.sh      # compiles build/Overlay.app with swiftc (no Xcode project)
    ./run.sh        # runs the default scene with live reload; Ctrl-C quits
    ./run.sh embers # runs a named scene from web/

Also quits from the `◆` menu bar item, which offers Reload and Hide too.

## How it works

Everything rests on a borderless, non-activating `NSPanel`:

| Behaviour | API |
|---|---|
| See-through | `isOpaque = false`, `backgroundColor = .clear`, `hasShadow = false` |
| **Clicks pass through** | `ignoresMouseEvents = true` |
| Above menu bar and Dock | `level = .screenSaver` (1000) |
| Every Space, over fullscreen apps | `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]` |
| Stays up when you focus another app | `hidesOnDeactivate = false` |
| Covers the menu bar strip | frame = `NSScreen.frame`, not `visibleFrame` |
| No Dock icon, never steals focus | `LSUIElement` + `setActivationPolicy(.accessory)` |
| Survives plugging in a projector | rebuild on `didChangeScreenParametersNotification` |
| Transparent web content | `WKWebView` + `setValue(false, forKey: "drawsBackground")` |

`ignoresMouseEvents` takes the window out of hit-testing altogether, so mouse,
scroll and gesture events are delivered to whatever sits underneath as if the
overlay were not there. **No permissions are required** — not Accessibility, not
Input Monitoring, not Screen Recording. The alternative approach, tapping events
with `CGEventTap` and re-posting them, would need Accessibility approval and
would add latency to every click on stage. We do not go near it.

### Two traps worth remembering

- `isFloatingPanel = true` silently resets the window level to `.floating` (3),
  which parks the overlay *under* the menu bar (24). Set `level` afterwards.
- `NSPanel` defaults `hidesOnDeactivate` to true, so the overlay would vanish the
  moment anything else takes focus. It must be explicitly turned off.

## Flags

    --file <path>     local HTML to display (default: the copy bundled in the .app)
    --url <url>       load a URL instead, e.g. a dev server on localhost
    --watch           reload when anything next to the HTML file changes
    --level <name>    shield | screensaver | menubar | floating | normal | <int>
    --screen <n|all>  which display to cover (default: main)
    --tint            paint the window faintly red, to verify its extent

`--level screensaver` (the default) covers everything, including open menus.
`--level menubar` (26) still covers the menu bar and Dock but lets app menus and
context menus draw above the overlay — better if you need to drive menus live.

## Pointing it at a website

    ./run.sh --url https://example.com
    ./run.sh --url http://localhost:5173        # a dev server

`--url` overrides the default local file; the last source flag on the command
line wins, so it beats the `--file` that `run.sh` passes for you. `--watch` turns
itself off for remote sources.

Two things to expect. Most real websites paint an opaque background, so pointing
this at one gives you a solid rectangle over the whole screen rather than an
overlay — only pages that are deliberately transparent work as set dressing.
And App Transport Security allows https anywhere and http on localhost; plain
http to another host is blocked unless `NSAllowsArbitraryLoads` is added to the
Info.plist in `build.sh`.

## Scenes

Each directory under `web/` is a scene, and `run.sh <name>` picks one.

- **leaves** (default) — opaque foliage clustered in the four corners with a few
  errant leaves drifting in the open, motes of light hovering like insects, and
  a slow firelight pulse from below the frame. Leaves stay in a black-to-green
  range: the fire never recolours them, it catches their edges.
- **embers** — the original corner-bracket test card. Four flush corner markers,
  drifting embers and a perimeter runner. Useful for confirming the window
  really does cover the whole display.

Scene knobs worth reaching for first, all near the top of `leaves.js`:
`LAYERS` (colour, size, density and sway per depth), `ANCHORS` (where the corner
clusters attach), `LIGHTS` (position and pulse rate of the fire), and the mote
and stray counts in `rebuild()`. `SEED` is fixed, so the composition is stable
across reloads — change it to deal a different arrangement.

## Writing the content

Corner content sits flush against the screen edge by default (`--inset` in
`overlay.css`). Note that the built-in MacBook display has rounded corners that
mask the outermost few pixels; an external projector does not.

`web/` is an ordinary page. Keep `html, body { background: transparent }` and
leave the middle clear so whatever is being demonstrated stays readable.

It is loaded over `file://`, so ES modules and `fetch` are blocked by CORS — use
a classic `<script>`, or serve the directory and pass `--url http://localhost:PORT`.

`:hover` never fires, by design: the window receives no mouse events at all.

To debug, open Safari's Develop menu and attach to the page (`isInspectable` is
on). You cannot right-click into an inspector on a click-through window.
