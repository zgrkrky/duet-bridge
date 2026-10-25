import AppKit
@preconcurrency import ApplicationServices
import Foundation

private let logURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Logs/DuetBridge.log")

func debugLog(_ message: String) {
    let line = "[\(Date())] \(message)\n"
    let path = logURL.path
    if let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int, size > 1_000_000 {
        try? FileManager.default.removeItem(atPath: path + ".1")
        try? FileManager.default.moveItem(atPath: path, toPath: path + ".1")
    }
    if !FileManager.default.fileExists(atPath: path) {
        FileManager.default.createFile(atPath: path, contents: nil)
    }
    guard let handle = try? FileHandle(forWritingTo: logURL) else { return }
    defer { try? handle.close() }
    _ = try? handle.seekToEnd()
    try? handle.write(contentsOf: Data(line.utf8))
}

/// Menu bar and overlay text follow the system language: Turkish or English.
let prefersTurkish = Locale.preferredLanguages.first?.hasPrefix("tr") == true

func L(_ english: String, _ turkish: String) -> String {
    prefersTurkish ? turkish : english
}

private final class Settings {
    private let defaults = UserDefaults.standard

    var target: OutputTarget {
        get { OutputTarget(rawValue: defaults.string(forKey: "target") ?? "") ?? .main }
        set { defaults.set(newValue.rawValue, forKey: "target") }
    }

    var stepDB: Double {
        get { defaults.object(forKey: "stepDB") as? Double ?? 2 }
        set { defaults.set(newValue, forKey: "stepDB") }
    }

    var overlayForExternalChanges: Bool {
        get { defaults.bool(forKey: "overlayForExternalChanges") }
        set { defaults.set(newValue, forKey: "overlayForExternalChanges") }
    }
}

@MainActor
private final class BridgeApp: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let glue = GlueClient()
    private let keys = MediaKeyTap()
    private let output = DefaultOutputWatcher()
    private let overlay = OverlayWindow()
    private let settings = Settings()
    private var statusItem: NSStatusItem!
    private var permissionTimer: Timer?

    func applicationDidFinishLaunching(_: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.menu = NSMenu()
        statusItem.menu?.delegate = self
        refreshStatusItem()

        glue.onChange = { [weak self] state, source in
            guard let self else { return }
            self.refreshStatusItem()
            if source == .external, self.settings.overlayForExternalChanges,
               let target = self.settings.target as OutputTarget?,
               let output = state?.outputs[target] {
                self.overlay.show(target: target, output: output)
            }
        }
        glue.start()

        keys.shouldIntercept = { [weak self] in
            guard let self else { return false }
            return self.output.isDuet && self.glue.state != nil
        }
        keys.onPress = { [weak self] in self?.handle($0) }
        installKeyTap()
        debugLog("duet-bridge \(Bundle.main.bundlePath) started")
    }

    // MARK: Keys

    private func installKeyTap() {
        if keys.install() {
            permissionTimer?.invalidate()
            permissionTimer = nil
            debugLog("event tap installed")
            refreshStatusItem()
            return
        }

        debugLog("event tap failed (AXIsProcessTrusted=\(AXIsProcessTrusted())); waiting for Accessibility permission")
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        guard permissionTimer == nil else { return }
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, AXIsProcessTrusted() else { return }
                self.installKeyTap()
            }
        }
    }

    private func handle(_ press: MediaKeyPress) {
        let useOther = press.flags.contains(.maskControl)
        let target = useOther ? settings.target.other : settings.target
        guard let current = glue.state?.outputs[target] else { return }

        let fine = press.flags.contains(.maskShift) && press.flags.contains(.maskAlternate)
        let step = fine ? 1 : settings.stepDB

        switch press.key {
        case .volumeUp, .volumeDown:
            if current.muted, press.key == .volumeUp { glue.setMuted(target, false) }
            glue.setGain(target, dB: current.gain + (press.key == .volumeUp ? step : -step))
        case .mute:
            guard !press.isRepeat else { return }
            if press.flags.contains(.maskAlternate) {
                glue.setDimmed(target, !current.dimmed)
            } else {
                glue.setMuted(target, !current.muted)
            }
        }

        if let updated = glue.state?.outputs[target] {
            overlay.show(target: target, output: updated)
        }
    }

    // MARK: Menu bar

    private func refreshStatusItem() {
        guard let button = statusItem?.button else { return }
        let target = settings.target
        let symbol: String
        let title: String
        if let output = glue.state?.outputs[target] {
            symbol = output.muted ? "speaker.slash.fill" : "speaker.wave.2.fill"
            title = output.muted ? "" : String(format: " %.0f", output.gain)
        } else {
            symbol = "speaker.badge.exclamationmark"
            title = ""
        }
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Duet")
        button.image?.isTemplate = true
        button.imagePosition = .imageLeading
        button.title = title
        button.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        if let state = glue.state {
            menu.addItem(disabled: L("\(state.name) — connected to ApogeeGlue", "\(state.name) — ApogeeGlue'ya bağlı"))
            for target in OutputTarget.allCases {
                guard let output = state.outputs[target] else { continue }
                let level = output.muted ? L("muted", "sessiz") : String(format: "%.0f dB", output.gain)
                menu.addItem(disabled: "\(target.label): \(level)\(output.dimmed ? " (Dim)" : "")")
                menu.addItem(action(L("Mute \(target.label)", "\(target.label) sesini kapat"), checked: output.muted) { [weak self] in
                    self?.glue.setMuted(target, !output.muted)
                })
            }
        } else {
            menu.addItem(disabled: L("Waiting for ApogeeGlue…", "ApogeeGlue bekleniyor…"))
        }
        if !output.isDuet {
            menu.addItem(disabled: L("Default output is not the Duet (\(output.deviceName)) — keys go to macOS", "Varsayılan çıkış Duet değil (\(output.deviceName)) — tuşlar macOS'a bırakılıyor"))
        }

        menu.addItem(.separator())

        let targetMenu = NSMenu()
        for target in OutputTarget.allCases {
            targetMenu.addItem(action(target.label, checked: settings.target == target) { [weak self] in
                self?.settings.target = target
                self?.refreshStatusItem()
            })
        }
        menu.addItem(submenu: L("Volume keys control", "Ses tuşları hedefi"), targetMenu)

        let stepMenu = NSMenu()
        for step in [1.0, 2.0, 3.0] {
            stepMenu.addItem(action(String(format: "%.0f dB", step), checked: settings.stepDB == step) { [weak self] in
                self?.settings.stepDB = step
            })
        }
        menu.addItem(submenu: L("Step", "Adım"), stepMenu)

        menu.addItem(action(L("Show overlay for knob changes too", "Fiziksel düğmede de göstergeyi göster"), checked: settings.overlayForExternalChanges) { [weak self] in
            guard let self else { return }
            self.settings.overlayForExternalChanges.toggle()
        })

        menu.addItem(.separator())
        menu.addItem(disabled: L("⌃ + volume: other output · ⇧⌥: 1 dB · ⌥ + mute: Dim", "⌃ + ses tuşları: diğer çıkış · ⇧⌥: 1 dB · ⌥ + sessiz: Dim"))
        if !keys.isInstalled {
            menu.addItem(action(L("⚠︎ Accessibility permission needed — Open Settings…", "⚠︎ Erişilebilirlik izni gerekli — Ayarları aç…")) {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
            })
            // An entry left by an older build is shown as enabled but does not
            // match this binary's signature, so it has to be removed first.
            menu.addItem(action(L("⚠︎ Permission may belong to an older build — reset and ask again", "⚠︎ İzin eski sürüme ait olabilir — sıfırla ve yeniden iste")) {
                let reset = Process()
                reset.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
                reset.arguments = ["reset", "Accessibility", "com.local.DuetBridge"]
                try? reset.run()
                reset.waitUntilExit()
                debugLog("tccutil reset Accessibility exited \(reset.terminationStatus)")
                let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                _ = AXIsProcessTrustedWithOptions(options)
            })
        }
        menu.addItem(action(L("Open Apogee Control 2", "Apogee Control 2'yi aç")) {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/Apogee Control 2.app"))
        })
        menu.addItem(.separator())
        menu.addItem(action(L("Quit Duet Bridge", "Duet Bridge'den çık")) { NSApp.terminate(nil) })
    }

    private func action(_ title: String, checked: Bool = false, _ handler: @escaping () -> Void) -> NSMenuItem {
        let item = ClosureMenuItem(title: title, handler: handler)
        item.state = checked ? .on : .off
        return item
    }
}

private final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder _: NSCoder) { fatalError() }

    @objc private func run() { handler() }
}

private extension NSMenu {
    func addItem(disabled title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        addItem(item)
    }

    func addItem(submenu title: String, _ submenu: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        addItem(item)
    }
}

// MARK: Command line

private func runCommandLine(_ arguments: [String]) -> Int32 {
    let glue = GlueClient()
    glue.start()
    let deadline = Date().addingTimeInterval(3)
    while glue.state == nil, Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
    guard let state = glue.state else {
        fputs("Could not reach ApogeeGlue or no Duet found.\n", stderr)
        return 1
    }

    func printState(_ state: DuetState) {
        print("\(state.name) (\(state.uid))")
        for target in OutputTarget.allCases {
            guard let output = state.outputs[target] else { continue }
            print(String(format: "  %@: %.1f dB mute=%@ dim=%@", target.rawValue, output.gain,
                         output.muted ? "on" : "off", output.dimmed ? "on" : "off"))
        }
    }

    let command = arguments.first ?? "--status"
    if command == "--status" {
        printState(state)
        return 0
    }

    guard arguments.count >= 2, let target = OutputTarget(rawValue: arguments[1].lowercased()),
          let output = state.outputs[target] else {
        fputs("""
        Usage:
          duet-bridge                       run as menu bar app
          duet-bridge --status
          duet-bridge --set  main|hp <dB>
          duet-bridge --step main|hp <+/-dB>
          duet-bridge --mute main|hp [on|off|toggle]
          duet-bridge --dim  main|hp [on|off|toggle]

        """, stderr)
        return 2
    }

    func toggle(_ current: Bool) -> Bool {
        switch arguments.count > 2 ? arguments[2].lowercased() : "toggle" {
        case "on", "1": true
        case "off", "0": false
        default: !current
        }
    }

    switch command {
    case "--set":
        guard arguments.count > 2, let value = Double(arguments[2]) else { return 2 }
        glue.setGain(target, dB: value)
    case "--step":
        guard arguments.count > 2, let value = Double(arguments[2]) else { return 2 }
        glue.setGain(target, dB: output.gain + value)
    case "--mute":
        glue.setMuted(target, toggle(output.muted))
    case "--dim":
        glue.setDimmed(target, toggle(output.dimmed))
    default:
        fputs("Unknown command: \(command)\n", stderr)
        return 2
    }
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    if let state = glue.state { printState(state) }
    return 0
}

private func acquireSingleInstanceLock() -> Bool {
    let fd = open(NSTemporaryDirectory() + "duet-bridge.lock", O_CREAT | O_RDWR, 0o600)
    return fd >= 0 && flock(fd, LOCK_EX | LOCK_NB) == 0
}

let arguments = Array(CommandLine.arguments.dropFirst()).filter { !$0.hasPrefix("-psn_") }
if arguments.first?.hasPrefix("--") == true, arguments.first != "--target" {
    exit(runCommandLine(arguments))
}

guard acquireSingleInstanceLock() else {
    fputs("duet-bridge is already running.\n", stderr)
    exit(0)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = BridgeApp()
    app.delegate = delegate
    app.run()
}
