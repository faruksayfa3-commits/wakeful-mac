import AppKit

// Health check: the first-run window, the "Health check…" menu item and `wakeful doctor` all show these.
// Every check only reads state; nothing here changes sleep settings.

struct Check {
    enum Level { case ok, info, warn, fail }
    var level: Level
    var title: String
    var detail: String
    var fix: String? = nil   // a command to paste into Terminal
}

enum Health {
    static var resources: String { Bundle.main.resourcePath ?? "/Applications/Wakeful.app/Contents/Resources" }

    /// The bundled script (zip / Homebrew installs have no checkout), else install.sh in the source tree.
    static var sudoersFix: String {
        let script = resources + "/setup-sudoers.sh"
        return FileManager.default.isExecutableFile(atPath: script) ? shQuote(script) : "./install.sh   # in your wakeful-mac checkout"
    }

    /// Slow (sudo, network): call it off the main thread. `cli` adds the "is the app running" check.
    static func run(cli: Bool = false) -> [Check] {
        var out: [Check] = []
        let configExists = FileManager.default.fileExists(atPath: Paths.config.path)
        let c = configExists ? Config.load() : Config()   // never create config.json from here

        // `sudo -l <cmd>` only asks whether the rule allows the command, it runs nothing. -n never prompts;
        // -k ignores a password cached in this terminal, so the CLI sees what the app (no terminal) gets.
        func allowed(_ args: String...) -> Bool { sh("/usr/bin/sudo", ["-n", "-k", "-l", "/usr/bin/pmset", "-a"] + args).status == 0 }
        if allowed("disablesleep", "0") && allowed("disablesleep", "1") {
            out.append(Check(level: .ok, title: "Sleep control", detail: "The sudoers rule lets Wakeful run pmset disablesleep without a password."))
            if !(allowed("lowpowermode", "0") && allowed("lowpowermode", "1")) {
                out.append(Check(level: .warn, title: "Economy mode", detail: "pmset lowpowermode isn't allowed, so economy mode does nothing. Re-run the setup to update the rule.", fix: sudoersFix))
            }
        } else {
            out.append(Check(level: .fail, title: "Sleep control",
                             detail: "The sudoers rule is missing, so Wakeful can't keep the Mac awake with the lid closed. Run this in Terminal (it asks for your password once):",
                             fix: sudoersFix))
        }
        out.append(Check(level: .info, title: "Sleep right now",
                         detail: sleepDisabledNow() ? "disablesleep is 1: the Mac won't sleep (a Wakeful session or another tool)." : "Normal sleep (disablesleep is 0)."))

        if cli {
            let me = getpid()
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: "app.wakeful.mac").contains { $0.processIdentifier != me }
            out.append(running ? Check(level: .ok, title: "App", detail: "Wakeful is running.")
                               : Check(level: .warn, title: "App", detail: "Wakeful is not running.", fix: "open -a Wakeful"))
        }

        if !configExists {
            out.append(Check(level: .info, title: "Settings", detail: "No config.json yet; it's created on first launch."))
        } else if (try? Data(contentsOf: Paths.config)).flatMap({ try? JSONSerialization.jsonObject(with: $0) }) == nil {
            out.append(Check(level: .fail, title: "Settings", detail: "config.json is not valid JSON, so Wakeful runs on defaults. Fix or delete it:",
                             fix: "open -e " + shQuote(Paths.config.path)))
        } else {
            out.append(Check(level: .ok, title: "Settings", detail: Paths.config.path))
        }

        if c.notifyPhone || c.phoneCommands {
            let topic = configExists ? c.ntfyTopic : "(created on first launch)"
            let sub = "Subscribe to \(topic) in the ntfy app" + (c.phoneCommands ? "; send off · on 2h · status to \(topic)-cmd." : ".")
            out.append(reachable(c.ntfyServer)
                       ? Check(level: .ok, title: "Phone (ntfy)", detail: "\(c.ntfyServer) is reachable. \(sub)")
                       : Check(level: .warn, title: "Phone (ntfy)", detail: "Can't reach \(c.ntfyServer) right now. \(sub)"))
        } else {
            out.append(Check(level: .info, title: "Phone (ntfy)", detail: "Notifications and commands are off."))
        }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if ["\(home)/.local/bin/wakeful", "/opt/homebrew/bin/wakeful", "/usr/local/bin/wakeful"].contains(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            out.append(Check(level: .ok, title: "Command line", detail: "The wakeful command is installed."))
        } else {
            out.append(Check(level: .info, title: "Command line", detail: "The wakeful command isn't installed. To add it:",
                             fix: "mkdir -p ~/.local/bin && ln -sf \(shQuote(resources + "/wakeful")) ~/.local/bin/wakeful"))
        }

        switch LaunchAtLogin.state {
        case .on: out.append(Check(level: .ok, title: "Launch at login", detail: "On."))
        case .off: out.append(Check(level: .info, title: "Launch at login", detail: "Off. Turn it on from the menu."))
        case .needsApproval: out.append(Check(level: .warn, title: "Launch at login", detail: "Waiting for approval in System Settings › General › Login Items."))
        }

        if let t = SMC.shared.temperature() {
            out.append(Check(level: .ok, title: "Temperature", detail: "\(Int(t))°C from the SMC."))
        } else {
            out.append(Check(level: .info, title: "Temperature", detail: "No SMC sensor found; the heat guard uses macOS thermal pressure instead."))
        }
        if sh("/usr/sbin/ioreg", ["-r", "-k", "AppleClamshellState", "-d", "1"]).out.contains("AppleClamshellState") {
            out.append(Check(level: .ok, title: "Lid sensor", detail: lidClosed() ? "Found (lid closed)." : "Found (lid open)."))
        } else {
            out.append(Check(level: .info, title: "Lid sensor", detail: "None (a desktop Mac): the lid-closed rules never apply."))
        }
        return out
    }

    /// Any HTTP answer counts: older self-hosted ntfy servers have no /v1/health.
    private static func reachable(_ server: String) -> Bool {
        guard let url = URL(string: server + "/v1/health") else { return false }
        let done = DispatchSemaphore(value: 0)
        var ok = false
        URLSession.shared.dataTask(with: URLRequest(url: url, timeoutInterval: 5)) { _, resp, _ in
            ok = resp is HTTPURLResponse; done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 6)
        return ok
    }

    static var platform: String {
        #if arch(arm64)
        let arch = "Apple Silicon"
        #else
        let arch = "Intel"
        #endif
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "Wakeful \(appVersion) · macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion) · \(arch)"
    }

    /// `wakeful doctor` (the CLI runs the app binary with --doctor). Exit status 1 when something must be fixed.
    static func doctor() -> Int32 {
        print("Wakeful doctor — \(platform)\n")
        let checks = run(cli: true)
        let width = checks.map(\.title.count).max() ?? 0
        for c in checks {
            let mark: String
            switch c.level { case .ok: mark = "✓"; case .info: mark = "·"; case .warn: mark = "!"; case .fail: mark = "✗" }
            print("  \(mark) \(c.title.padding(toLength: width, withPad: " ", startingAt: 0))  \(c.detail)")
            if let f = c.fix { print("      \(f)") }
        }
        let failed = checks.contains { $0.level == .fail }
        print(failed ? "\nSomething needs fixing (✗ above)." : "\nAll good.")
        return failed ? 1 : 0
    }
}

// MARK: - window (first run + "Health check…")

final class HealthWindow: NSObject {
    private let window: NSWindow
    private let content = NSStackView()
    private var actions: [Action] = []
    private let firstRun: Bool
    private let topic: () -> String
    private let openSettings: () -> Void

    init(firstRun: Bool, topic: @escaping () -> String, openSettings: @escaping () -> Void) {
        self.firstRun = firstRun
        self.topic = topic
        self.openSettings = openSettings
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 300), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        window.title = firstRun ? "Welcome to Wakeful" : "Wakeful Health Check"
        window.isReleasedWhenClosed = false
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 12
        content.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        window.contentView = content
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        refresh()
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    func close() { window.close() }

    private func refresh() {
        render(nil)
        DispatchQueue.global().async {
            let checks = Health.run()
            DispatchQueue.main.async { self.render(checks) }
        }
    }

    private func render(_ checks: [Check]?) {
        content.arrangedSubviews.forEach { $0.removeFromSuperview() }
        actions = []
        let head = firstRun ? "Wakeful keeps your Mac awake, lid closed too, only while an agent or a long task is working."
                            : "What Wakeful needs to work, and how to fix what's missing."
        content.addArrangedSubview(fullWidth(label(head, wrap: true)))

        guard let checks else {
            let spin = NSProgressIndicator()
            spin.style = .spinning; spin.controlSize = .small; spin.startAnimation(nil)
            content.addArrangedSubview(hstack([spin, label("Checking…", secondary: true)]))
            fit(); return
        }
        for c in checks {
            let (symbol, color): (String, NSColor) = {
                switch c.level {
                case .ok: return ("checkmark.circle.fill", .systemGreen)
                case .info: return ("info.circle", .secondaryLabelColor)
                case .warn: return ("exclamationmark.triangle.fill", .systemOrange)
                case .fail: return ("xmark.octagon.fill", .systemRed)
                }
            }()
            let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
            icon.contentTintColor = color
            icon.setContentHuggingPriority(.required, for: .horizontal)
            var text: [NSView] = [label(c.title, weight: .semibold), fullWidth(label(c.detail, secondary: true, wrap: true), 470)]
            if let fix = c.fix { text.append(copyable(fix, maxWidth: 470)) }
            let col = NSStackView(views: text)
            col.orientation = .vertical; col.alignment = .leading; col.spacing = 2
            let row = hstack([icon, col])
            row.alignment = .top
            content.addArrangedSubview(fullWidth(row))
        }

        let t = topic()
        content.addArrangedSubview(label("Your phone topic (keep it secret, it's the only password)", weight: .semibold))
        content.addArrangedSubview(copyable(t))

        let again = button("Check again") { [weak self] in self?.refresh() }
        let settings = button("Settings…") { [weak self] in self?.window.close(); self?.openSettings() }
        let done = button("Done") { [weak self] in self?.window.close() }
        done.keyEquivalent = "\r"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        content.addArrangedSubview(fullWidth(hstack([again, spacer, settings, done])))
        fit()
    }

    /// Monospaced, selectable command with a Copy button.
    private func copyable(_ s: String, maxWidth: CGFloat = 500) -> NSView {
        let f = NSTextField(wrappingLabelWithString: s)
        f.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        f.lineBreakMode = .byCharWrapping
        f.preferredMaxLayoutWidth = maxWidth - 70   // leaves room for the Copy button
        let copy = button("Copy") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(s, forType: .string)
        }
        copy.controlSize = .small
        let row = hstack([f, copy])
        row.widthAnchor.constraint(lessThanOrEqualToConstant: maxWidth).isActive = true
        return row
    }

    private func button(_ title: String, _ fn: @escaping () -> Void) -> NSButton {
        let a = Action { _ in fn() }
        actions.append(a)
        return NSButton(title: title, target: a, action: #selector(Action.fire(_:)))
    }

    private func fullWidth(_ v: NSView, _ width: CGFloat = 500) -> NSView {
        v.translatesAutoresizingMaskIntoConstraints = false
        v.widthAnchor.constraint(equalToConstant: width).isActive = true
        return v
    }

    private func fit() {
        content.layoutSubtreeIfNeeded()
        window.setContentSize(NSSize(width: 540, height: content.fittingSize.height))
    }
}
