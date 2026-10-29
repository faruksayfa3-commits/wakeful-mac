import AppKit

// Wakeful — keeps your Mac awake (lid closed too) while something that matters is still running.

final class PhoneCommands {
    static let staleAfter: TimeInterval = 600
    private final class LineBuffer { var data = Data() }   // one per connection, only touched on its pipe's handler queue
    private var proc: Process?
    private var generation = 0          // bumped on restart: the old connection's callbacks and reconnect then do nothing
    private var lastID: String?         // last command seen; a reconnect asks ntfy for everything after it
    private var connectedAt: Int?       // unix time of the first connection, the `since` to use until a command arrives
    var handler: ((String) -> Void)?

    func start() {
        guard Notifier.config.phoneCommands else { return }
        let c = Notifier.config
        generation += 1
        let gen = generation
        // Commands sent while we were reconnecting (the 30 s gap, sleep, a Wi-Fi change) are still in ntfy's cache:
        // ask for everything after the last one we saw, or since we first connected, instead of only new ones.
        var url = "\(c.ntfyServer)/\(c.ntfyTopic)-cmd/json"
        if let id = lastID { url += "?since=\(id)" }
        else if let t = connectedAt { url += "?since=\(t)" }
        else { connectedAt = Int(Date().timeIntervalSince1970) }
        let buffer = LineBuffer()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        // ntfy sends a keepalive every ~45 s; no bytes for 120 s means a dead connection (sleep, Wi-Fi change) → reconnect
        p.arguments = ["-sN", "--max-time", "86400", "--speed-limit", "1", "--speed-time", "120", url]
        let pipe = Pipe()
        p.standardOutput = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let chunk = h.availableData
            if chunk.isEmpty { h.readabilityHandler = nil; return }   // EOF: otherwise the handler keeps firing
            buffer.data.append(chunk)
            while let nl = buffer.data.firstIndex(of: 10) {
                let line = buffer.data.subdata(in: 0..<nl)
                buffer.data.removeSubrange(0...nl)
                guard let o = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      o["event"] as? String == "message", let m = o["message"] as? String else { continue }
                let id = o["id"] as? String, time = o["time"] as? Double
                DispatchQueue.main.async {
                    guard let self, gen == self.generation else { return }
                    if let id { self.lastID = id }
                    // a replayed command from long ago (the Mac slept through it) is stale, not an order
                    if let time, Date().timeIntervalSince1970 - time > PhoneCommands.staleAfter { return }
                    self.handler?(m.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
                }
            }
        }
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) {   // reconnect
                guard let self, gen == self.generation else { return }
                self.start()
            }
        }
        try? p.run()
        proc = p
    }

    /// Server, topic or the on/off switch changed: drop the connection and start over on the new topic.
    func restart() {
        generation += 1
        proc?.terminate(); proc = nil
        lastID = nil; connectedAt = nil
        start()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private let engine = Engine()
    private let phone = PhoneCommands()
    private var eyeT: CGFloat = -1, eyeFrom: CGFloat = 0, eyeTo: CGFloat = 0
    private var eyeStart = Date()
    private var eyeTimer: Timer?
    private var lastMood: Mood?, lastTheme = ""
    private var settings: SettingsWindow?
    private var health: HealthWindow?

    private let durations: [(String, TimeInterval)] = [
        ("30 minutes", 1800), ("1 hour", 3600), ("2 hours", 7200), ("4 hours", 14400),
        ("8 hours", 28800), ("12 hours", 43200), ("24 hours", 86400),
    ]

    func applicationDidFinishLaunching(_ notification: Notification) {
        let me = NSRunningApplication.current
        if NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "").contains(where: { $0 != me }) {
            NSApp.terminate(nil); return
        }
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleURL(_:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
        item.autosaveName = "wakeful"
        menu.delegate = self
        menu.autoenablesItems = false   // so the isEnabled values set in menuNeedsUpdate (e.g. "Stop") take effect
        item.menu = menu
        engine.onChange = { [weak self] in self?.refreshIcon() }
        engine.start()
        phone.handler = { [weak self] cmd in self?.phoneCommand(cmd) }
        phone.start()
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
        installEditMenu()
        // first launch (1.0 users see it once too): what works, the phone topic, and the fix for anything missing
        if !UserDefaults.standard.bool(forKey: "onboarded") {
            UserDefaults.standard.set(true, forKey: "onboarded")
            showHealth(firstRun: true)
        }
    }

    /// An accessory app shows no menu bar, but key equivalents still go through mainMenu:
    /// without one, ⌘C / ⌘V / ⌘A / ⌘W do nothing in the Settings and Health windows.
    private func installEditMenu() {
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let main = NSMenu(), editItem = NSMenuItem()
        editItem.submenu = edit
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    /// Every config change (menu, Settings window) goes through here: save, hand it to the engine,
    /// restart what depends on it.
    private func apply(_ c: Config, fromSettings: Bool = false) {
        let old = engine.config
        engine.config = c
        c.save()
        if c.phoneCommands != old.phoneCommands || c.ntfyServer != old.ntfyServer || c.ntfyTopic != old.ntfyTopic { phone.restart() }
        if !fromSettings { settings?.reload(c) }
        refreshIcon()
        engine.tick()
    }

    @objc private func didWake() { engine.tick() }

    func applicationWillTerminate(_ notification: Notification) { engine.shutdown() }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        item.button?.performClick(nil); return false
    }

    // MARK: URL scheme  wakeful://on?for=2h  |  on?until=07:00  |  off  |  watch?name=rsync  |  report

    @objc private func handleURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let s = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue, let u = URLComponents(string: s) else { return }
        let q = Dictionary((u.queryItems ?? []).compactMap { i in i.value.map { (i.name, $0) } }, uniquingKeysWith: { a, _ in a })
        switch u.host ?? "" {
        case "on":
            if let f = q["for"], let d = parseDuration(f) { engine.startManual(duration: d) }
            else if let t = q["until"], let d = nextTime(t) { engine.startManual(duration: nil, until: d) }
            else { engine.startManual(duration: nil) }
        case "off": engine.stopManual()
        case "watch": if let n = q["name"] { engine.startManual(duration: nil, watch: n) }
        case "report": openLastReport()
        default: break
        }
    }

    private func phoneCommand(_ cmd: String) {
        let parts = cmd.split(separator: " ").map(String.init)
        switch parts.first ?? "" {
        case "off", "sleep", "panic":
            engine.stopManual()
            Notifier.phone("Wakeful", "Stopping. Mac will sleep normally.", tags: "zzz")
        case "on":
            let d = parts.count > 1 ? parseDuration(parts[1]) : 4 * 3600
            engine.startManual(duration: min(d ?? 4 * 3600, 12 * 3600))
            Notifier.phone("Wakeful", "Awake for \(fmtDuration(min(d ?? 4 * 3600, 12 * 3600))).", tags: "eyes")
        case "status":
            Notifier.phone("Wakeful status", engine.statusLine() + " · battery \(engine.power.percent)%" + (engine.tempC.map { " · \(Int($0))°C" } ?? ""))
        default:
            Notifier.phone("Wakeful", "Commands: off · on [2h] · status", tags: "information_source")
        }
    }

    // MARK: icon

    private func refreshIcon() {
        let theme = engine.config.theme, mood = engine.mood
        defer { lastMood = mood; lastTheme = theme }
        if theme != "eye" {
            item.button?.image = themedIcon(theme: theme, mood: mood, t: 0); eyeT = -1
        } else {
            let target = lid(for: mood)
            if eyeT < 0 || lastTheme != theme {
                eyeT = target; eyeTo = target
                item.button?.image = themedIcon(theme: "eye", mood: mood, t: target)
            } else if target != eyeTo || mood != lastMood {
                eyeFrom = eyeT; eyeTo = target; eyeStart = Date()
                eyeTimer?.invalidate()
                let tm = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.eyeStep() }
                RunLoop.main.add(tm, forMode: .common)
                eyeTimer = tm
            }
        }
        item.button?.toolTip = engine.statusLine()
    }

    private func eyeStep() {
        let p = min(1, Date().timeIntervalSince(eyeStart) / 0.5)
        eyeT = eyeFrom + (eyeTo - eyeFrom) * CGFloat(p * p * (3 - 2 * p))
        item.button?.image = themedIcon(theme: "eye", mood: engine.mood, t: eyeT)
        if p >= 1 { eyeTimer?.invalidate(); eyeTimer = nil }
    }

    // MARK: menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let c = engine.config
        add(engine.statusLine(), enabled: false)
        if !engine.reasons.isEmpty { add("Because: " + engine.reasons.joined(separator: ", "), enabled: false) }
        var sensors = "Battery \(engine.power.percent)%" + (engine.power.onAC ? " (plugged in)" : "")
        if let t = engine.tempC { sensors += " · \(Int(t))°C" }
        add(sensors, enabled: false)
        menu.addItem(.separator())

        let forMenu = NSMenu()
        for (i, d) in durations.enumerated() { add(d.0, #selector(startFor(_:)), tag: i, to: forMenu) }
        add("Until I stop it", #selector(startFor(_:)), tag: -1, to: forMenu)
        let forItem = NSMenuItem(title: "Stay awake for…", action: nil, keyEquivalent: ""); forItem.submenu = forMenu
        menu.addItem(forItem)

        let untilMenu = NSMenu()
        for t in ["06:00", "07:00", "08:00", "09:00"] { add("Until \(t)", #selector(startUntil(_:)), represented: t, to: untilMenu) }
        let untilItem = NSMenuItem(title: "Stay awake until…", action: nil, keyEquivalent: ""); untilItem.submenu = untilMenu
        menu.addItem(untilItem)

        add("Wait for a process…", #selector(askWatch))
        let stop = add("Stop — let it sleep", #selector(stopNow)); stop.isEnabled = engine.session != nil || engine.manualOn
        menu.addItem(.separator())

        let auto = NSMenu()
        toggle("Agents & long tasks (Claude, Codex, rsync…)", \.autoWatch, in: auto)
        toggle("Open SSH / Screen Sharing session", \.keepWhileRemote, in: auto)
        toggle("Only when plugged in", \.onlyOnAC, in: auto)
        auto.addItem(.separator())
        toggle("Lock screen when the lid closes", \.lockOnLidClose, in: auto)
        toggle("Turn display off when the lid closes", \.displayOffOnLidClose, in: auto)
        toggle("Keep Wi-Fi alive with the lid closed", \.wifiKeepAlive, in: auto)
        toggle("Economy mode on battery", \.economyMode, in: auto)
        toggle("Backpack mode (sleep if it warms up on battery)", \.backpackMode, in: auto)
        toggle("Phone notifications", \.notifyPhone, in: auto)
        let autoItem = NSMenuItem(title: "Rules", action: nil, keyEquivalent: ""); autoItem.submenu = auto
        menu.addItem(autoItem)

        let themes = NSMenu()
        for th in ["eye", "cat", "robot"] {
            let m = add(th.capitalized, #selector(setTheme(_:)), represented: th, to: themes)
            m.state = c.theme == th ? .on : .off
            m.image = themedIcon(theme: th, mood: .awake, t: 0)
        }
        let themeItem = NSMenuItem(title: "Icon", action: nil, keyEquivalent: ""); themeItem.submenu = themes
        menu.addItem(themeItem)
        menu.addItem(.separator())

        add("Last night's report", #selector(openLastReport))
        add("Copy phone topic (ntfy)", #selector(copyTopic))
        add("Send test notification", #selector(testNotify))
        menu.addItem(.separator())
        add("Settings…", #selector(openSettings), key: ",")
        add("Health check…", #selector(openHealth))
        let login = LaunchAtLogin.state
        let li = add(login == .needsApproval ? "Launch at login (approve in System Settings)" : "Launch at login", #selector(toggleLogin))
        li.state = login == .on ? .on : login == .needsApproval ? .mixed : .off
        add("Check for updates…", #selector(checkUpdates))
        add("Open settings file", #selector(openConfig))
        menu.addItem(.separator())
        add("Quit Wakeful", #selector(quit), key: "q")
    }

    @discardableResult
    private func add(_ title: String, _ action: Selector? = nil, tag: Int = 0, represented: String? = nil, key: String = "",
                     enabled: Bool = true, to m: NSMenu? = nil) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: key)
        it.target = self; it.tag = tag; it.representedObject = represented; it.isEnabled = enabled && action != nil
        (m ?? menu).addItem(it)
        return it
    }

    private func toggle(_ title: String, _ kp: WritableKeyPath<Config, Bool>, in m: NSMenu) {
        let it = NSMenuItem(title: title, action: #selector(flip(_:)), keyEquivalent: "")
        it.target = self
        it.state = engine.config[keyPath: kp] ? .on : .off
        it.representedObject = KeyPathBox(kp)
        m.addItem(it)
    }

    final class KeyPathBox { let kp: WritableKeyPath<Config, Bool>; init(_ k: WritableKeyPath<Config, Bool>) { kp = k } }

    @objc private func flip(_ s: NSMenuItem) {
        guard let box = s.representedObject as? KeyPathBox else { return }
        var c = engine.config
        c[keyPath: box.kp].toggle()
        apply(c)
    }

    @objc private func startFor(_ s: NSMenuItem) { engine.startManual(duration: s.tag >= 0 ? durations[s.tag].1 : nil) }
    @objc private func startUntil(_ s: NSMenuItem) {
        if let t = s.representedObject as? String, let d = nextTime(t) { engine.startManual(duration: nil, until: d) }
    }
    @objc private func stopNow() { engine.stopManual() }
    @objc private func setTheme(_ s: NSMenuItem) {
        var c = engine.config
        c.theme = (s.representedObject as? String) ?? "eye"
        apply(c)
    }

    @objc private func openSettings() {
        if settings == nil { settings = SettingsWindow(config: engine.config) { [weak self] c in self?.apply(c, fromSettings: true) } }
        settings?.show(engine.config)
    }
    @objc private func openHealth() { showHealth(firstRun: false) }
    private func showHealth(firstRun: Bool) {
        health?.close()
        health = HealthWindow(firstRun: firstRun, topic: { [weak self] in self?.engine.config.ntfyTopic ?? "" },
                              openSettings: { [weak self] in self?.openSettings() })
        health?.show()
    }
    @objc private func toggleLogin() {
        let err: String?
        switch LaunchAtLogin.state {
        case .needsApproval: LaunchAtLogin.openSystemSettings(); return
        case .on: err = LaunchAtLogin.set(false)
        case .off: err = LaunchAtLogin.set(true)
        }
        if let err { alert("Launch at login", err) }
    }
    @objc private func checkUpdates() {
        Updates.check { [weak self] r in
            switch r {
            case let .newer(v, page):
                NSApp.activate(ignoringOtherApps: true)
                let a = NSAlert()
                a.messageText = "Wakeful \(v) is available"
                a.informativeText = "You have \(appVersion). The release page has the download and what changed."
                a.addButton(withTitle: "Open Release Page"); a.addButton(withTitle: "Later")
                if a.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(page) }
            case let .upToDate(v): self?.alert("Wakeful is up to date", "You have \(appVersion); the latest release is \(v).")
            case .noRelease: self?.alert("No releases yet", "Nothing has been published on GitHub so far.")
            case let .failed(why): self?.alert("Couldn't check for updates", why)
            }
        }
    }
    private func alert(_ title: String, _ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }
    @objc private func askWatch() {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "Stay awake until a process finishes"
        a.informativeText = "Process name (e.g. rsync, xcodebuild) or PID."
        let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        a.accessoryView = f
        a.addButton(withTitle: "Watch"); a.addButton(withTitle: "Cancel")
        if a.runModal() == .alertFirstButtonReturn, !f.stringValue.isEmpty { engine.startManual(duration: nil, watch: f.stringValue) }
    }
    @objc private func openLastReport() {
        let files = (try? FileManager.default.contentsOfDirectory(at: Paths.reports, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        if let png = files.filter({ $0.pathExtension == "png" }).max(by: { $0.path < $1.path }) { NSWorkspace.shared.open(png) }
        else if let md = files.filter({ $0.pathExtension == "md" }).max(by: { $0.path < $1.path }) { NSWorkspace.shared.open(md) }
        else { Notifier.local("Wakeful", "No report yet — it appears after the first awake session.") }
    }
    @objc private func copyTopic() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(engine.config.ntfyTopic, forType: .string)
        Notifier.local("Wakeful", "Topic copied. In the ntfy app subscribe to it (and to \(engine.config.ntfyTopic)-cmd to send commands).")
    }
    @objc private func testNotify() { Notifier.say("Wakeful test", "If you see this on your phone, notifications work.") }
    @objc private func openConfig() { NSWorkspace.shared.open(Paths.config) }
    @objc private func quit() { NSApp.terminate(nil) }   // applicationWillTerminate restores sleep
}

// `wakeful doctor` runs this binary with --doctor: print the health check and exit, no menu-bar app.
if CommandLine.arguments.dropFirst().first == "--doctor" { exit(Health.doctor()) }

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// pkill / launchctl bootout / logout send SIGTERM: quit through AppKit so disablesleep is given back.
signal(SIGTERM, SIG_IGN)
let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
sigterm.setEventHandler { NSApp.terminate(nil) }
sigterm.resume()
app.setActivationPolicy(.accessory)
app.run()
