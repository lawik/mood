//
//  KeyTap — intercepts key presses and forwards them to the scene runner.
//
//  This is the one part of Overlay that needs Accessibility permission, which is
//  why it only exists behind --capture-keys. The overlay on its own still needs
//  no permissions at all.
//
//  Three properties matter more than anything else here, because a tap that
//  swallows keystrokes can leave a machine with no usable keyboard:
//
//    1. Fail open. Keys are only swallowed while the connection to the scene
//       runner is up. If it drops, dies, or was never there, every key passes
//       through untouched.
//    2. Command and Control are never touched, so Cmd-Tab, Cmd-Q and the menu
//       bar always work.
//    3. Escape is never swallowed and always disables capture. It is the panic
//       key, and it is worth knowing before you need it. Command-Escape turns
//       capture back on, and Command-Left/Right step between scenes.
//
//  The tap also runs its own thread and run loop. Sharing the main run loop with
//  WKWebView means a render stall can trip kCGEventTapDisabledByTimeout, and
//  macOS then silently disables the tap mid-scene.
//

import AppKit
import CoreGraphics
import Network

private final class Flag {
    private let lock = NSLock()
    private var value: Bool
    init(_ value: Bool) { self.value = value }
    var isSet: Bool {
        lock.lock(); defer { lock.unlock() }
        return value
    }
    func set(_ newValue: Bool) {
        lock.lock(); value = newValue; lock.unlock()
    }
}

private func escapeJSON(_ s: String) -> String {
    var out = ""
    for scalar in s.unicodeScalars {
        switch scalar {
        case "\"": out += "\\\""
        case "\\": out += "\\\\"
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        default:
            if scalar.value < 0x20 {
                out += String(format: "\\u%04x", scalar.value)
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
    }
    return out
}

final class KeyTap {
    private let host: String
    private let port: UInt16

    private let connected = Flag(false)
    private let enabled = Flag(true)          // toggled off by the panic key

    private var machPort: CFMachPort?
    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "se.underjord.overlay.keytap")
    private var reconnectDelay: TimeInterval = 0.25

    /// Called on the main queue whenever capture starts or stops, for the menu.
    var onStateChange: ((Bool) -> Void)?

    /// Capture is actually swallowing keys: the operator wants it on *and* the
    /// runner is there to receive them.
    var isCapturing: Bool { enabled.isSet && connected.isSet }

    /// The operator's switch on its own, regardless of the connection.
    var isEnabled: Bool { enabled.isSet }

    init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }

    // MARK: Lifecycle

    func start() {
        guard requestAccessibility() else {
            print("""
                  Overlay: key capture needs Accessibility permission.
                  Grant it in System Settings > Privacy & Security > Accessibility,
                  add build/Overlay.app, then run again.
                  """)
            return
        }
        connect()
        let thread = Thread { [weak self] in self?.runTapLoop() }
        thread.name = "se.underjord.overlay.keytap"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    func setEnabled(_ on: Bool) {
        enabled.set(on)
        notify()
    }

    private func notify() {
        let state = isCapturing
        DispatchQueue.main.async { [weak self] in self?.onStateChange?(state) }
    }

    private func requestAccessibility() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        return AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    // MARK: Tap

    private func runTapLoop() {
        let mask = (1 << CGEventType.keyDown.rawValue)
                 | (1 << CGEventType.flagsChanged.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,                 // .listenOnly cannot swallow
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let tap = Unmanaged<KeyTap>.fromOpaque(refcon).takeUnretainedValue()
                return tap.handle(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            print("Overlay: could not create the key tap (permission refused?)")
            return
        }

        machPort = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        print("Overlay: key tap armed, forwarding to \(host):\(port)")
        CFRunLoopRun()
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // macOS disables a tap that was too slow; re-arm it rather than going
        // quietly deaf for the rest of the show.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let machPort { CGEvent.tapEnable(tap: machPort, enable: true) }
            return nil
        }

        guard type == .keyDown else { return Unmanaged.passUnretained(event) }

        let keycode = Int(event.getIntegerValueField(.keyboardEventKeycode))

        // 53 is Escape. On its own it is the panic key; with Command it turns
        // capture back on. Two separate gestures rather than one toggle, so the
        // resulting state never depends on what the state was.
        if keycode == 53 {
            if event.flags.contains(.maskCommand) {
                if !enabled.isSet {
                    enabled.set(true)
                    notify()
                    print("Overlay: command-escape, key capture re-enabled")
                }
                // Swallowed: this is our own control gesture, and letting it
                // reach the focused app would be sloppy. It is the one Command
                // combination that does not pass through.
                return nil
            }

            if enabled.isSet {
                enabled.set(false)
                notify()
                print("Overlay: escape pressed, key capture disabled")
            }
            return Unmanaged.passUnretained(event)
        }

        let flags = event.flags

        // 123 and 124 are Left and Right. With Command held they step the scene
        // runner through scenes/ in filename order. Gated on capture being live,
        // so Command-arrow behaves normally whenever a scene is not running.
        if flags.contains(.maskCommand), keycode == 123 || keycode == 124, isCapturing {
            transmit(command: keycode == 124 ? "scene_next" : "scene_prev")
            return nil
        }

        if flags.contains(.maskCommand) || flags.contains(.maskControl) {
            return Unmanaged.passUnretained(event)
        }

        guard isCapturing else { return Unmanaged.passUnretained(event) }

        var length = 0
        var buffer = [UniChar](repeating: 0, count: 8)
        event.keyboardGetUnicodeString(maxStringLength: 8,
                                       actualStringLength: &length,
                                       unicodeString: &buffer)
        let chars = length > 0 ? String(utf16CodeUnits: buffer, count: length) : ""

        send(keycode: keycode, chars: chars, flags: flags)
        return nil                                  // swallowed: the actor's
                                                    // own keystrokes never land
    }

    // MARK: Transport

    private func send(keycode: Int, chars: String, flags: CGEventFlags) {
        var mods: [String] = []
        if flags.contains(.maskShift) { mods.append("\"shift\"") }
        if flags.contains(.maskAlternate) { mods.append("\"alt\"") }
        transmit("{\"type\":\"key\",\"keycode\":\(keycode),"
               + "\"chars\":\"\(escapeJSON(chars))\","
               + "\"mods\":[\(mods.joined(separator: ","))]}\n")
    }

    private func transmit(command name: String) {
        print("Overlay: \(name)")
        transmit("{\"type\":\"command\",\"name\":\"\(escapeJSON(name))\"}\n")
    }

    private func transmit(_ line: String) {
        // Off the tap thread: a blocking write here would stall input and trip
        // the tap timeout.
        queue.async { [weak self] in
            guard let self, let connection = self.connection else { return }
            connection.send(content: Data(line.utf8),
                            completion: .contentProcessed { error in
                if error != nil { self.dropConnection() }
            })
        }
    }

    private func connect() {
        let endpoint = NWEndpoint.Host(host)
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }

        let connection = NWConnection(host: endpoint, port: nwPort, using: .tcp)
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.reconnectDelay = 0.25
                self.connected.set(true)
                self.notify()
                print("Overlay: scene runner connected")
            case .failed, .cancelled:
                self.dropConnection()
            case .waiting:
                // Connection refused on loopback lands here, which is exactly
                // the case of mood being started before the scene runner.
                // NWConnection can sit in .waiting rather than retrying
                // promptly, so drive the retry ourselves. This is what makes
                // the start order of the two processes irrelevant.
                self.dropConnection()
            default:
                break
            }
        }
        self.connection = connection
        connection.start(queue: queue)
    }

    private func dropConnection() {
        guard connected.isSet || connection != nil else { return }
        connected.set(false)                        // fail open, immediately
        notify()
        connection?.cancel()
        connection = nil
        queue.asyncAfter(deadline: .now() + reconnectDelay) { [weak self] in
            guard let self else { return }
            self.reconnectDelay = min(self.reconnectDelay * 2, 5)
            self.connect()
        }
    }
}
