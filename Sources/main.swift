//
//  Overlay — a transparent, click-through WKWebView pinned above the desktop.
//
//  The whole trick is four AppKit settings, applied to a borderless non-activating
//  NSPanel:
//
//    isOpaque = false / backgroundColor = .clear   see through to the desktop
//    ignoresMouseEvents = true                     removed from hit-testing entirely,
//                                                  so clicks/scroll/gestures land on
//                                                  whatever is underneath
//    level = .screenSaver                          draws above the menu bar and Dock
//    collectionBehavior = [.canJoinAllSpaces,      present on every Space, and over
//                          .fullScreenAuxiliary]   other apps' fullscreen windows
//
//  No event taps, so no Accessibility or Input Monitoring permission is needed.
//

import AppKit
import WebKit

// MARK: - Configuration

enum ScreenTarget {
    case primary
    case all
    case index(Int)
    case name(String)
}

struct Config {
    var source: URL
    var watchRoot: URL?
    var level: NSWindow.Level
    var target: ScreenTarget
    var tint: Bool
    var captureKeys: (host: String, port: UInt16)?

    /// Per-display page overrides, first match wins. Extended mode puts a
    /// different overlay on each display: the performer's prompter on the one
    /// they can see, the set dressing on the one the audience can see.
    var perScreen: [(target: ScreenTarget, url: URL)] = []
}

private func windowLevel(named name: String) -> NSWindow.Level? {
    switch name.lowercased() {
    case "shield":      return NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
    case "screensaver": return .screenSaver
    case "menubar":     return NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
    case "floating":    return .floating
    case "normal":      return .normal
    default:            return Int(name).map(NSWindow.Level.init(rawValue:))
    }
}

/// One spelling of a display, shared by --screen and --url-on.
func screenTarget(_ raw: String) -> ScreenTarget {
    switch raw.lowercased() {
    case "all":             return .all
    case "primary", "main": return .primary
    default:
        // An index if it parses as one, otherwise match on display name, which
        // survives reconnecting a projector where an index may not.
        return Int(raw).map(ScreenTarget.index) ?? .name(raw)
    }
}

func listScreens() -> Never {
    let screens = NSScreen.screens
    if screens.isEmpty {
        print("Overlay: no displays reported")
        exit(0)
    }
    for (i, screen) in screens.enumerated() {
        let f = screen.frame
        let primary = (i == 0) ? "  (primary)" : ""
        print("[\(i)] \(screen.localizedName)  "
            + "\(Int(f.width))x\(Int(f.height)) at \(Int(f.origin.x)),\(Int(f.origin.y))"
            + "\(primary)")
    }
    exit(0)
}

let defaultOverlayURL = "http://localhost:4040/overlay"

private let usage = """
Overlay — transparent click-through web layer for macOS

  --url <url>       page to display (default: http://localhost:4040/overlay)
  --file <path>     a local HTML file instead of a URL
  --watch           reload whenever anything beside the HTML file changes
  --level <name>    shield | screensaver | menubar | floating | normal | <int>
                    default: screensaver (above the menu bar and Dock)
  --screen <spec>   which displays to cover: all (the default), primary, an
                    index, or part of a display name (case-insensitive)
  --list-screens    print the attached displays and exit
  --tint            paint the window faintly red to verify its extent
  --url-on <spec>=<url>
                    a different page on one display, repeatable. <spec> is the
                    same as --screen: primary, an index, or part of a name.
                    e.g. --url-on primary=http://localhost:4040/prompter
  --capture-keys [host:port]
                    swallow key presses and forward them to a scene runner
                    (default 127.0.0.1:4041). Needs Accessibility permission.
                    Keys only get swallowed while the runner is connected.
                    Escape disables capture; Command-Escape re-enables it.
                    Command-Left/Right step through scenes on the runner.
  --check-permission
                    report whether Accessibility is granted, and exit
  --help

Ctrl-C in this terminal quits, as does Quit in the ◆ menu bar item.
"""

func parseConfig() -> Config {
    var source: URL?
    var watch = false
    var level: NSWindow.Level = .screenSaver
    var target: ScreenTarget = .all
    var tint = false
    var captureKeys: (host: String, port: UInt16)? = nil
    var perScreen: [(target: ScreenTarget, url: URL)] = []

    var args = Array(CommandLine.arguments.dropFirst())
    while let arg = args.first {
        args.removeFirst()
        func value(_ name: String) -> String {
            guard let v = args.first else {
                FileHandle.standardError.write("Overlay: \(name) needs a value\n".data(using: .utf8)!)
                exit(2)
            }
            args.removeFirst()
            return v
        }
        switch arg {
        case "--file":
            source = URL(fileURLWithPath: value("--file")).standardizedFileURL
        case "--url":
            guard let u = URL(string: value("--url")) else {
                FileHandle.standardError.write("Overlay: --url is not a valid URL\n".data(using: .utf8)!)
                exit(2)
            }
            source = u
        case "--watch":
            watch = true
        case "--level":
            let raw = value("--level")
            guard let l = windowLevel(named: raw) else {
                FileHandle.standardError.write("Overlay: unknown --level \(raw)\n".data(using: .utf8)!)
                exit(2)
            }
            level = l
        case "--screen":
            target = screenTarget(value("--screen"))
        case "--list-screens":
            listScreens()
        case "--url-on":
            let raw = value("--url-on")
            guard let split = raw.firstIndex(of: "="),
                  let overrideURL = URL(string: String(raw[raw.index(after: split)...])),
                  overrideURL.scheme != nil else {
                FileHandle.standardError.write("Overlay: --url-on wants <spec>=<url>\n".data(using: .utf8)!)
                exit(2)
            }
            perScreen.append((screenTarget(String(raw[..<split])), overrideURL))
        case "--capture-keys":
            var spec = "127.0.0.1:4041"
            if let next = args.first, !next.hasPrefix("-") {
                spec = next
                args.removeFirst()
            }
            let parts = spec.split(separator: ":")
            let host = parts.count > 1 ? String(parts[0]) : "127.0.0.1"
            let rawPort = parts.count > 1 ? parts[1] : parts[0]
            guard let portValue = UInt16(rawPort) else {
                FileHandle.standardError.write("Overlay: --capture-keys wants [host:]port\n".data(using: .utf8)!)
                exit(2)
            }
            captureKeys = (host, portValue)
        case "--tint":
            tint = true
        case "--check-permission":
            // The exact check macOS makes before it will hand out an event tap.
            // Deliberately does not create a tap: an enabled tap with no run
            // loop attached would sit in the event stream until it timed out.
            if AXIsProcessTrusted() {
                print("Accessibility: granted. Key capture will work.")
                exit(0)
            }
            print("""
                  Accessibility: NOT granted for this process.

                  If Overlay.app is already listed and enabled in System Settings,
                  the likely cause is how it was launched. macOS attributes
                  Accessibility to the *responsible* process, and a binary exec'd
                  from a terminal is attributed to the terminal, not to the app.
                  Launch through LaunchServices instead:

                    open -a \(Bundle.main.bundlePath) --args --check-permission

                  ./run.sh does this automatically for --capture-keys.

                  Otherwise, add it under
                  System Settings > Privacy & Security > Accessibility:
                    \(Bundle.main.bundlePath)
                  """)
            exit(1)
        case "--help", "-h":
            print(usage)
            exit(0)
        default:
            FileHandle.standardError.write("Overlay: unknown argument \(arg)\n\n\(usage)\n".data(using: .utf8)!)
            exit(2)
        }
    }

    // The overlay is scener's LiveView. There is no bundled page: this app is a
    // chrome-less window and a key tap, and the visuals belong with the scenes.
    let resolved = source ?? URL(string: defaultOverlayURL)!

    return Config(source: resolved,
                  watchRoot: (watch && resolved.isFileURL) ? resolved.deletingLastPathComponent() : nil,
                  level: level,
                  target: target,
                  tint: tint,
                  captureKeys: captureKeys,
                  perScreen: perScreen)
}

// MARK: - Window

/// Refuses key and main status outright, so focus never leaves whatever the
/// audience is actually looking at.
final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override var acceptsFirstResponder: Bool { false }
}

final class OverlaySurface: NSObject, WKNavigationDelegate {
    let panel: OverlayPanel
    let webView: WKWebView

    // The scene runner may not be up yet, or may restart mid-rehearsal. A page
    // that failed to load once should not stay a WebKit error page for the rest
    // of the night, so failures retry until they stop failing. Same reasoning as
    // the key tap's reconnect: start order should not matter.
    private var page: URL?
    private var retryDelay: TimeInterval = 0.5
    private var retrying = false

    init(screen: NSScreen, config: Config) {
        let wkConfig = WKWebViewConfiguration()
        // Lets Safari's Develop menu attach to the page; there is no way to
        // right-click into an inspector on a click-through window.
        wkConfig.preferences.setValue(true, forKey: "developerExtrasEnabled")

        webView = WKWebView(frame: NSRect(origin: .zero, size: screen.frame.size),
                            configuration: wkConfig)
        // The one private hop we need: WKWebView otherwise paints opaque white
        // beneath the page no matter how transparent the CSS is.
        webView.setValue(false, forKey: "drawsBackground")
        webView.underPageBackgroundColor = .clear
        webView.isInspectable = true
        webView.allowsMagnification = false
        webView.allowsBackForwardNavigationGestures = false
        webView.autoresizingMask = [.width, .height]
        webView.wantsLayer = true
        webView.layer?.backgroundColor = .clear

        panel = OverlayPanel(contentRect: screen.frame,
                             styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered,
                             defer: false,
                             screen: screen)

        panel.isOpaque = false
        panel.backgroundColor = config.tint
            ? NSColor.systemRed.withAlphaComponent(0.12)
            : .clear
        panel.hasShadow = false

        // Input pass-through.
        panel.ignoresMouseEvents = true

        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        // NSPanel hides itself when the owning app deactivates — which is always,
        // for an accessory app. Turning that off is what keeps the overlay up.
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true

        // Must be set AFTER isFloatingPanel: that setter quietly forces the level
        // back to .floating (3), which parks the overlay under the menu bar.
        panel.level = config.level
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        // Stay visible in screen recordings / OBS captures of the stage feed.
        panel.sharingType = .readWrite

        panel.contentView = webView
        panel.setFrame(screen.frame, display: true)

        super.init()
    }

    func load(_ url: URL) {
        page = url
        webView.navigationDelegate = self

        if url.isFileURL {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            webView.load(URLRequest(url: url))
        }
    }

    func reload() {
        guard let page else { return }
        load(page)
    }

    /// A plain re-load re-fetches the HTML but serves CSS and JS out of
    /// WebKit's cache, so edits appear to do nothing. Clearing the cache first
    /// is what makes --watch actually live.
    func reloadIgnoringCache() {
        let types: Set<String> = [WKWebsiteDataTypeMemoryCache, WKWebsiteDataTypeDiskCache]
        webView.configuration.websiteDataStore
            .removeData(ofTypes: types, modifiedSince: .distantPast) { [weak self] in
                self?.reload()
            }
    }

    // MARK: Retrying

    func webView(_ webView: WKWebView,
                 didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        retry(after: error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        retry(after: error)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if retrying {
            print("Overlay: page loaded")
            retrying = false
        }
        retryDelay = 0.5
    }

    private func retry(after error: Error) {
        // -999 is a navigation we cancelled ourselves by starting another one.
        // Retrying on that would chase its own tail.
        if (error as NSError).code == NSURLErrorCancelled { return }
        guard let url = page else { return }

        if !retrying {
            print("Overlay: \(url.absoluteString) did not load "
                + "(\(error.localizedDescription)); retrying until it does")
            retrying = true
        }

        let delay = retryDelay
        retryDelay = min(retryDelay * 2, 5)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.load(url)
        }
    }

    func show() {
        panel.orderFrontRegardless()
    }

    func close() {
        panel.orderOut(nil)
        panel.contentView = nil
        panel.close()
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let config: Config
    private var surfaces: [OverlaySurface] = []
    private var statusItem: NSStatusItem?
    private var watchTimer: DispatchSourceTimer?
    private var keyTap: KeyTap?
    private var captureItem: NSMenuItem?
    private var lastSeenChange: Date = .distantPast
    private var hidden = false

    init(config: Config) {
        self.config = config
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // No Dock icon, no menu bar of its own, never becomes frontmost.
        NSApp.setActivationPolicy(.accessory)

        if let capture = config.captureKeys {
            let tap = KeyTap(host: capture.host, port: capture.port)
            tap.onStateChange = { [weak self] active in
                self?.captureItem?.title = active ? "Key capture: ON" : "Key capture: idle"
            }
            // Refuse to run half-armed. An overlay that looks right while
            // silently ignoring the actor's keys is worse than one that does
            // not start, and it would only be noticed once the show began.
            guard tap.start() else { exit(1) }
            keyTap = tap
        }

        rebuildSurfaces()
        installStatusItem()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil)

        if let root = config.watchRoot {
            lastSeenChange = Self.newestModification(under: root)
            startWatching(root)
            print("Overlay: watching \(root.path) for changes")
        }

        print("Overlay: \(surfaces.count) display(s) at level \(config.level.rawValue)")
    }

    // MARK: Surfaces

    private func targetScreens() -> [NSScreen] {
        let all = NSScreen.screens
        guard !all.isEmpty else { return [] }

        func fallback(_ why: String) -> [NSScreen] {
            let names = all.map { $0.localizedName }.joined(separator: ", ")
            print("Overlay: \(why); covering all displays instead (\(names))")
            return all
        }

        switch config.target {
        case .all:
            return all
        case .primary:
            // screens[0] is the display holding the menu bar. NSScreen.main is
            // whichever display has the active window, which for an accessory
            // app that never takes focus is not something to rely on.
            return [all[0]]
        case .index(let i):
            guard i >= 0, i < all.count else { return fallback("no display at index \(i)") }
            return [all[i]]
        case .name(let needle):
            let matches = all.filter {
                $0.localizedName.range(of: needle, options: .caseInsensitive) != nil
            }
            guard !matches.isEmpty else { return fallback("no display matching '\(needle)'") }
            return matches
        }
    }

    private func rebuildSurfaces() {
        surfaces.forEach { $0.close() }
        let all = NSScreen.screens

        surfaces = targetScreens().map { screen in
            let index = all.firstIndex(of: screen) ?? 0
            let url = page(for: screen, at: index)
            let surface = OverlaySurface(screen: screen, config: config)
            surface.load(url)
            if !hidden { surface.show() }
            print("Overlay: [\(index)] \(screen.localizedName) -> \(url.absoluteString)")
            return surface
        }
    }

    /// Which page a given display shows. First matching --url-on wins, so the
    /// performer's display can carry a prompter while the projected one carries
    /// the set dressing.
    private func page(for screen: NSScreen, at index: Int) -> URL {
        let chosen = config.perScreen.first { matches(screen, at: index, $0.target) }?.url
        return tagged(chosen ?? config.source, screen: screen, at: index)
    }

    private func matches(_ screen: NSScreen, at index: Int, _ target: ScreenTarget) -> Bool {
        switch target {
        case .all: return true
        case .primary: return index == 0
        case .index(let wanted): return wanted == index
        case .name(let needle):
            return screen.localizedName.range(of: needle, options: .caseInsensitive) != nil
        }
    }

    /// Tell the page which display it landed on, so a single page can also serve
    /// both roles without needing --url-on at all.
    private func tagged(_ url: URL, screen: NSScreen, at index: Int) -> URL {
        guard !url.isFileURL,
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }

        var items = parts.queryItems ?? []
        items.append(URLQueryItem(name: "screen", value: String(index)))
        items.append(URLQueryItem(name: "primary", value: index == 0 ? "true" : "false"))
        items.append(URLQueryItem(name: "display", value: screen.localizedName))
        parts.queryItems = items
        return parts.url ?? url
    }

    /// Plugging in a projector, changing resolution or rearranging displays all
    /// land here. Rebuilding is cheap and avoids stale geometry.
    @objc private func screenParametersChanged() {
        print("Overlay: display configuration changed, re-laying out")
        rebuildSurfaces()
    }

    // MARK: Menu bar item

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "◆"
        item.button?.toolTip = "Overlay"

        let menu = NSMenu()
        menu.addItem(withTitle: "Reload", action: #selector(reload), keyEquivalent: "r")
        if config.captureKeys != nil {
            let capture = NSMenuItem(title: "Key capture: idle",
                                     action: #selector(toggleCapture),
                                     keyEquivalent: "")
            menu.addItem(capture)
            captureItem = capture
        }
        let toggle = NSMenuItem(title: "Hide Overlay", action: #selector(toggleVisible), keyEquivalent: "h")
        menu.addItem(toggle)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Overlay", action: #selector(quit), keyEquivalent: "q")
        menu.items.forEach { $0.target = self }
        item.menu = menu
        statusItem = item
    }

    @objc private func reload() {
        surfaces.forEach { $0.reloadIgnoringCache() }
    }

    @objc private func toggleVisible(_ sender: NSMenuItem) {
        hidden.toggle()
        hidden ? surfaces.forEach { $0.panel.orderOut(nil) }
               : surfaces.forEach { $0.show() }
        sender.title = hidden ? "Show Overlay" : "Hide Overlay"
    }

    @objc private func toggleCapture() {
        guard let keyTap else { return }
        keyTap.setEnabled(!keyTap.isEnabled)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: Live reload

    private static func newestModification(under root: URL) -> Date {
        var newest = Date.distantPast
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else {
            return newest
        }
        for case let url as URL in walker {
            if let date = try? url.resourceValues(forKeys: Set(keys)).contentModificationDate,
               date > newest {
                newest = date
            }
        }
        return newest
    }

    private func startWatching(_ root: URL) {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let newest = Self.newestModification(under: root)
            if newest > self.lastSeenChange {
                self.lastSeenChange = newest
                print("Overlay: reloading")
                self.reload()
            }
        }
        timer.resume()
        watchTimer = timer
    }
}

// MARK: - Entry point

// Line-buffer stdout: it is block-buffered whenever it is not a terminal, and
// this app is usually launched with its output going to a file or a pipe.
setvbuf(stdout, nil, _IOLBF, 0)

let app = NSApplication.shared
let delegate = AppDelegate(config: parseConfig())
app.delegate = delegate
app.run()
