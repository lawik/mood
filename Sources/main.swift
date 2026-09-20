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
    case main
    case all
    case index(Int)
}

struct Config {
    var source: URL
    var watchRoot: URL?
    var level: NSWindow.Level
    var target: ScreenTarget
    var tint: Bool
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

private let usage = """
Overlay — transparent click-through web layer for macOS

  --file <path>     local HTML file to display (default: bundled web/index.html)
  --url <url>       load a URL instead (e.g. a dev server on http://localhost:5173)
  --watch           reload whenever anything beside the HTML file changes
  --level <name>    shield | screensaver | menubar | floating | normal | <int>
                    default: screensaver (above the menu bar and Dock)
  --screen <n|all>  which display to cover (default: main)
  --tint            paint the window faintly red to verify its extent
  --help

Ctrl-C in this terminal quits, as does Quit in the ◆ menu bar item.
"""

func parseConfig() -> Config {
    var source: URL?
    var watch = false
    var level: NSWindow.Level = .screenSaver
    var target: ScreenTarget = .main
    var tint = false

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
            let raw = value("--screen")
            if raw.lowercased() == "all" {
                target = .all
            } else if let n = Int(raw) {
                target = .index(n)
            } else {
                FileHandle.standardError.write("Overlay: --screen wants a number or 'all'\n".data(using: .utf8)!)
                exit(2)
            }
        case "--tint":
            tint = true
        case "--help", "-h":
            print(usage)
            exit(0)
        default:
            FileHandle.standardError.write("Overlay: unknown argument \(arg)\n\n\(usage)\n".data(using: .utf8)!)
            exit(2)
        }
    }

    let resolved = source
        ?? Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "web/leaves")
        ?? URL(fileURLWithPath: "web/leaves/index.html").standardizedFileURL

    return Config(source: resolved,
                  watchRoot: (watch && resolved.isFileURL) ? resolved.deletingLastPathComponent() : nil,
                  level: level,
                  target: target,
                  tint: tint)
}

// MARK: - Window

/// Refuses key and main status outright, so focus never leaves whatever the
/// audience is actually looking at.
final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override var acceptsFirstResponder: Bool { false }
}

final class OverlaySurface {
    let panel: OverlayPanel
    let webView: WKWebView

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
    }

    func load(_ config: Config) {
        if config.source.isFileURL {
            webView.loadFileURL(config.source,
                                allowingReadAccessTo: config.source.deletingLastPathComponent())
        } else {
            webView.load(URLRequest(url: config.source))
        }
    }

    /// A plain re-load re-fetches the HTML but serves CSS and JS out of
    /// WebKit's cache, so edits appear to do nothing. Clearing the cache first
    /// is what makes --watch actually live.
    func reload(_ config: Config) {
        let types: Set<String> = [WKWebsiteDataTypeMemoryCache, WKWebsiteDataTypeDiskCache]
        webView.configuration.websiteDataStore
            .removeData(ofTypes: types, modifiedSince: .distantPast) { [weak self] in
                self?.load(config)
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
    private var lastSeenChange: Date = .distantPast
    private var hidden = false

    init(config: Config) {
        self.config = config
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // No Dock icon, no menu bar of its own, never becomes frontmost.
        NSApp.setActivationPolicy(.accessory)

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

        let where_ = config.source.isFileURL ? config.source.path : config.source.absoluteString
        print("Overlay: showing \(where_) on \(surfaces.count) display(s) at level \(config.level.rawValue)")
    }

    // MARK: Surfaces

    private func targetScreens() -> [NSScreen] {
        let all = NSScreen.screens
        guard !all.isEmpty else { return [] }
        switch config.target {
        case .all:
            return all
        case .main:
            return [NSScreen.main ?? all[0]]
        case .index(let i):
            guard i >= 0, i < all.count else {
                print("Overlay: no display \(i), falling back to main")
                return [NSScreen.main ?? all[0]]
            }
            return [all[i]]
        }
    }

    private func rebuildSurfaces() {
        surfaces.forEach { $0.close() }
        surfaces = targetScreens().map { screen in
            let surface = OverlaySurface(screen: screen, config: config)
            surface.load(config)
            if !hidden { surface.show() }
            return surface
        }
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
        let toggle = NSMenuItem(title: "Hide Overlay", action: #selector(toggleVisible), keyEquivalent: "h")
        menu.addItem(toggle)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Overlay", action: #selector(quit), keyEquivalent: "q")
        menu.items.forEach { $0.target = self }
        item.menu = menu
        statusItem = item
    }

    @objc private func reload() {
        surfaces.forEach { $0.reload(config) }
    }

    @objc private func toggleVisible(_ sender: NSMenuItem) {
        hidden.toggle()
        hidden ? surfaces.forEach { $0.panel.orderOut(nil) }
               : surfaces.forEach { $0.show() }
        sender.title = hidden ? "Show Overlay" : "Hide Overlay"
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

let app = NSApplication.shared
let delegate = AppDelegate(config: parseConfig())
app.delegate = delegate
app.run()
