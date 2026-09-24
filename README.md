# Overlay

A transparent, click-through web layer pinned above everything else on macOS.
Built for stage use: the projected desktop stays fully usable — terminals,
editors, whatever — while this draws set dressing on top of it.

    ./build.sh      # compiles build/Overlay.app with swiftc (no Xcode project)
    ./run.sh        # the whole thing: scener's overlay + key capture

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
overlay were not there. **The overlay itself requires no permissions** — not
Accessibility, not Input Monitoring, not Screen Recording. The alternative for
clicks, tapping events with `CGEventTap` and re-posting them, would need
Accessibility approval and would add latency to every click on stage. We do not
go near it: mouse events are never tapped.

Keyboard is the exception, and only on request. `--capture-keys` does use a
`CGEventTap`, because intercepting keystrokes is the entire point of it. See
[Key capture](#key-capture); without that flag none of it is active.

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
    --screen <spec>   which displays to cover: all (the default), primary, an
                      index, or part of a display name (case-insensitive)
    --list-screens    print the attached displays and exit
    --tint            paint the window faintly red, to verify its extent

`--level screensaver` (the default) covers everything, including open menus.
`--level menubar` (26) still covers the menu bar and Dock but lets app menus and
context menus draw above the overlay — better if you need to drive menus live.

## Displays

By default the overlay covers every attached display, one window per screen.

    ./run.sh --list-screens        # [0] Built-in Retina Display  1470x956 at 0,0  (primary)
    ./run.sh --screen 1            # by index
    ./run.sh --screen "DELL"       # by name, case-insensitive substring
    ./run.sh --screen primary      # the display holding the menu bar
    ./run.sh --screen all          # the default, stated explicitly

Prefer selecting by name for a venue: indices shuffle when displays are
reconnected or rearranged, names do not. A `--screen` that matches nothing falls
back to covering all displays and says so on stdout rather than failing.

`primary` means `NSScreen.screens[0]`, the display holding the menu bar — not
`NSScreen.main`, which is whichever display has the active window and is
meaningless for an app that never takes focus.

Plugging a projector in, unplugging it, or changing resolution fires
`didChangeScreenParametersNotification` and the windows are rebuilt against the
new arrangement. Each display gets its own web view, so animation runs
independently per screen — they are not frame-synced with each other.

## Key capture

`--capture-keys [host:port]` makes the overlay swallow key presses and forward
them to a scene runner as newline-delimited JSON over TCP (default
`127.0.0.1:4041`). An actor taps any keys; the runner decides what actually gets
typed.

    ./run.sh                    # capture is on by default
    ./run.sh --check-permission

**Missing permission is fatal.** The app exits rather than drawing an overlay
that looks right while silently ignoring every key, and `run.sh` checks before
it draws anything at all. That failure would otherwise only surface once the
show had started.

| | |
|---|---|
| **Escape** | disables capture. The panic key: never swallowed, works always. |
| **Command-Escape** | re-enables capture. |
| **Command-Left / Right** | step to the previous / next scene on the runner. |
| **Command / Control** | otherwise never swallowed, so Cmd-Tab, Cmd-Q and the menu bar always work. |

Two gestures rather than one toggle, so the resulting state never depends on
what the state was — worth something when you are reaching for it in a hurry.

Command-Escape and Command-Left/Right are the only Command combinations that do
not pass through, being the overlay's own control gestures. The arrows are
further gated on capture being live, so they behave normally whenever a scene is
not running — otherwise the overlay would eat a shortcut that plenty of apps use
for navigation. The runner steps through `scenes/` in filename order and runs the
outgoing scene's teardown on the way out.

Keys are only swallowed **while the runner is connected**. If the runner dies or
was never started, every key passes through untouched — a tap that suppressed
everything with nothing listening would leave you unable to type the command
that would fix it. The two can be started in either order; the overlay retries
until the runner appears.

### Why run.sh uses `open` for this

macOS attributes Accessibility to the *responsible process*, and a binary
exec'd from a terminal is attributed to the terminal, not to the app. Adding
`Overlay.app` under Privacy & Security would then never apply and the tap would
silently do nothing. So `run.sh` launches through LaunchServices for
`--capture-keys` and `--check-permission`, which makes the app responsible for
itself. Plain scene runs still exec directly.

`build.sh` signs with a real codesigning identity when one exists, which keeps
the grant across rebuilds. An ad-hoc signature pins the requirement to the
cdhash, so every rebuild looks like a different app and the permission resets.

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

## Where the visuals come from

scener's LiveView at `http://localhost:4040/overlay`, so scene state and the set
dressing are driven by one process. `OVERLAY_URL` points it elsewhere.

**A page that fails to load keeps retrying** rather than sitting on a WebKit
error page for the rest of the night. Start the overlay before the runner, or
restart the runner mid-rehearsal, and the page comes back on its own within a
few seconds. The failure is logged once, not once per attempt. Same reasoning as
the key tap's reconnect: the order you start things in should not matter.

The leaves used to be a local page here and now live in scener, which owns the
animation, the scene indicator and anything else that reacts to a cue. Nothing
is bundled in the `.app` any more: this is a chrome-less window and a key tap,
and the visuals belong with the scenes.

`--file` still takes a local page if you want one. To check the window really
covers the whole display without anything else running, `--tint` paints it
faintly red, which is a better test than any page.


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
