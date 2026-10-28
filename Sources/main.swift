import AppKit

// Vigil — keeps your Mac awake (lid closed too) while something that matters is still running.

final class PhoneCommands {
    private var proc: Process?
    private var buffer = Data()
    var handler: ((String) -> Void)?

    func start() {
        guard Notifier.config.phoneCommands else { return }
        let c = Notifier.config
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        p.arguments = ["-sN", "--max-time", "86400", "\(c.ntfyServer)/\(c.ntfyTopic)-cmd/json"]
        let pipe = Pipe()
        p.standardOutput = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            guard let self else { return }
            self.buffer.append(h.availableData)
            while let nl = self.buffer.firstIndex(of: 10) {
                let line = self.buffer.subdata(in: 0..<nl)
                self.buffer.removeSubrange(0...nl)
                if let o = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                   o["event"] as? String == "message", let m = o["message"] as? String {
                    DispatchQueue.main.async { self.handler?(m.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) }
                }
            }
        }
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { self?.start() }   // reconnect
        }
        try? p.run()
        proc = p
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
        item.autosaveName = "vigil"
        menu.delegate = self
        item.menu = menu
        engine.onChange = { [weak self] in self?.refreshIcon() }
        engine.start()
        phone.handler = { [weak self] cmd in self?.phoneCommand(cmd) }
        phone.start()
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
    }

    @objc private func didWake() { engine.tick() }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        item.button?.performClick(nil); return false
    }

    // MARK: URL scheme  vigil://on?for=2h  |  on?until=07:00  |  off  |  watch?name=rsync  |  report

    @objc private func handleURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let s = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue, let u = URLComponents(string: s) else { return }
        let q = Dictionary(uniqueKeysWithValues: (u.queryItems ?? []).compactMap { i in i.value.map { (i.name, $0) } })
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
            Notifier.phone("Vigil", "Stopping. Mac will sleep normally.", tags: "zzz")
        case "on":
            let d = parts.count > 1 ? parseDuration(parts[1]) : 4 * 3600
            engine.startManual(duration: min(d ?? 4 * 3600, 12 * 3600))
            Notifier.phone("Vigil", "Awake for \(fmtDuration(min(d ?? 4 * 3600, 12 * 3600))).", tags: "eyes")
        case "status":
            Notifier.phone("Vigil status", engine.statusLine() + " · battery \(engine.power.percent)%" + (engine.tempC.map { " · \(Int($0))°C" } ?? ""))
        default:
            Notifier.phone("Vigil", "Commands: off · on [2h] · status", tags: "information_source")
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
        add("Open settings file", #selector(openConfig))
        menu.addItem(.separator())
        add("Quit Vigil", #selector(quit), key: "q")
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
        engine.config[keyPath: box.kp].toggle()
        engine.config.save()
        engine.tick()
    }

    @objc private func startFor(_ s: NSMenuItem) { engine.startManual(duration: s.tag >= 0 ? durations[s.tag].1 : nil) }
    @objc private func startUntil(_ s: NSMenuItem) {
        if let t = s.representedObject as? String, let d = nextTime(t) { engine.startManual(duration: nil, until: d) }
    }
    @objc private func stopNow() { engine.stopManual() }
    @objc private func setTheme(_ s: NSMenuItem) {
        engine.config.theme = (s.representedObject as? String) ?? "eye"; engine.config.save(); refreshIcon()
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
        else { Notifier.local("Vigil", "No report yet — it appears after the first awake session.") }
    }
    @objc private func copyTopic() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(engine.config.ntfyTopic, forType: .string)
        Notifier.local("Vigil", "Topic copied. In the ntfy app subscribe to it (and to \(engine.config.ntfyTopic)-cmd to send commands).")
    }
    @objc private func testNotify() { Notifier.say("Vigil test", "If you see this on your phone, notifications work.") }
    @objc private func openConfig() { NSWorkspace.shared.open(Paths.config) }
    @objc private func quit() {
        if engine.session != nil, engine.awake { _ = engine.setSleepDisabled(false) }
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
