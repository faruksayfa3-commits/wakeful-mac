import AppKit

// Settings window: plain AppKit (SwiftUI's Settings scene needs macOS 13). Every change is applied at once:
// the window hands the new Config to `onChange`, which saves config.json and updates Engine.config.

/// Target-action for closures: AppKit controls want an object and a selector.
final class Action: NSObject {
    private let fn: (Any) -> Void
    init(_ fn: @escaping (Any) -> Void) { self.fn = fn }
    @objc func fire(_ sender: Any) { fn(sender) }
}

func label(_ s: String, size: CGFloat = NSFont.systemFontSize, weight: NSFont.Weight = .regular, secondary: Bool = false, wrap: Bool = false) -> NSTextField {
    let f = wrap ? NSTextField(wrappingLabelWithString: s) : NSTextField(labelWithString: s)
    f.font = .systemFont(ofSize: size, weight: weight)
    if secondary { f.textColor = .secondaryLabelColor }
    return f
}

func hstack(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
    let s = NSStackView(views: views)
    s.orientation = .horizontal
    s.alignment = .centerY
    s.spacing = spacing
    return s
}

private final class FlippedView: NSView { override var isFlipped: Bool { true } }   // scroll content starts at the top

final class SettingsWindow: NSObject, NSWindowDelegate {
    private var window: NSWindow!
    private var config: Config
    private let onChange: (Config) -> Void
    private var actions: [Action] = []
    private var loaders: [(Config) -> Void] = []   // how each control shows a Config; reload() replays them
    private var agents: StringListEditor!, tasks: StringListEditor!
    private let scheduleStack = NSStackView()
    private var scheduleRows: [ScheduleRow] = []
    private let noSchedules = label("No schedules yet.", secondary: true)

    init(config: Config, onChange: @escaping (Config) -> Void) {
        self.config = config
        self.onChange = onChange
        super.init()
        build()
        reload(config)
    }

    func show(_ c: Config) {
        reload(c)
        NSApp.activate(ignoringOtherApps: true)
        if !window.isVisible { window.center() }
        window.makeKeyAndOrderFront(nil)
    }

    /// The config changed elsewhere (menu toggles): show it.
    func reload(_ c: Config) {
        config = c
        loaders.forEach { $0(c) }
    }

    var isVisible: Bool { window.isVisible }

    func windowWillClose(_ notification: Notification) { window.makeFirstResponder(nil) }   // commits a field still being edited

    private func commit(_ change: (inout Config) -> Void) {
        change(&config)
        onChange(config)
    }

    // MARK: layout

    private func build() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 500), styleMask: [.titled, .closable, .miniaturizable],
                          backing: .buffered, defer: false)
        window.title = "Wakeful Settings"
        window.isReleasedWhenClosed = false
        window.delegate = self
        let tabs = NSTabView()
        for (title, view) in [("General", general()), ("Watch", watch()), ("Safety", safety()), ("Phone", phone()), ("Schedules", schedules())] {
            let item = NSTabViewItem(identifier: title)
            item.label = title
            item.view = page(view)
            tabs.addTabViewItem(item)
        }
        let root = NSView()
        tabs.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(tabs)
        NSLayoutConstraint.activate([
            tabs.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            tabs.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            tabs.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            tabs.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
        ])
        window.contentView = root
    }

    /// Pins a tab's content to its top-left; the rest of the tab stays empty.
    private func page(_ v: NSView) -> NSView {
        let p = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        p.addSubview(v)
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: p.topAnchor, constant: 16),
            v.leadingAnchor.constraint(equalTo: p.leadingAnchor, constant: 20),
            v.trailingAnchor.constraint(lessThanOrEqualTo: p.trailingAnchor, constant: -20),
            v.bottomAnchor.constraint(lessThanOrEqualTo: p.bottomAnchor, constant: -16),
        ])
        return p
    }

    private func vstack(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .vertical
        s.alignment = .leading
        s.spacing = spacing
        return s
    }

    private func section(_ title: String, _ views: [NSView]) -> NSView {
        let s = vstack([label(title, weight: .semibold)] + views, spacing: 6)
        s.setCustomSpacing(8, after: s.arrangedSubviews[0])
        return s
    }

    private func help(_ s: String) -> NSTextField {
        let l = label(s, size: NSFont.smallSystemFontSize, secondary: true, wrap: true)
        l.preferredMaxLayoutWidth = 600
        return l
    }

    /// Label column right-aligned, controls left-aligned.
    private func form(_ rows: [(String, NSView)]) -> NSGridView {
        let g = NSGridView(views: rows.map { [label($0.0), $0.1] })
        g.rowSpacing = 8
        g.columnSpacing = 10
        g.column(at: 0).xPlacement = .trailing
        g.rowAlignment = .firstBaseline
        return g
    }

    // MARK: tabs

    private func general() -> NSView {
        let theme = NSPopUpButton()
        let themes = ["eye", "cat", "robot"]
        for th in themes {
            theme.addItem(withTitle: th.capitalized)
            theme.lastItem?.image = themedIcon(theme: th, mood: .awake, t: 0)
        }
        bind(theme) { [unowned self] _ in self.commit { $0.theme = themes[max(0, theme.indexOfSelectedItem)] } }
        loaders.append { theme.selectItem(at: themes.firstIndex(of: $0.theme) ?? 0) }

        return vstack([
            section("Stay awake automatically", [
                checkbox("While agents and long tasks are working (lists in Watch)", \.autoWatch),
                checkbox("While an SSH or Screen Sharing session is open", \.keepWhileRemote),
                checkbox("Only when plugged in", \.onlyOnAC),
            ]),
            section("When the lid closes", [
                checkbox("Lock the screen", \.lockOnLidClose),
                checkbox("Turn the display off", \.displayOffOnLidClose),
                checkbox("Keep Wi-Fi alive", \.wifiKeepAlive),
                checkbox("Economy mode (Low Power Mode) on battery", \.economyMode),
            ]),
            section("Menu-bar icon", [theme]),
        ], spacing: 20)
    }

    private func watch() -> NSView {
        agents = StringListEditor { [unowned self] v in self.commit { $0.agents = v } }
        tasks = StringListEditor { [unowned self] v in self.commit { $0.tasks = v } }
        loaders.append { [unowned self] in self.agents.set($0.agents); self.tasks.set($0.tasks) }
        let lists = hstack([
            section("Agents", [agents.view, help("Awake while they use CPU, and for the grace time after.")]),
            section("Tasks", [tasks.view, help("Awake for as long as they run.")]),
        ], spacing: 24)
        lists.alignment = .top
        return vstack([
            lists,
            help("Process names as ps shows them (claude, rsync, xcodebuild). Double-click a name to edit it."),
            form([
                ("Agent grace time:", number("min", 1...240, get: { Double($0.activityGraceMin) }, set: { $0.activityGraceMin = Int($1) })),
                ("Looks stuck after:", number("min without CPU", 1...720, get: { Double($0.stuckMin) }, set: { $0.stuckMin = Int($1) })),
            ]),
        ], spacing: 14)
    }

    private func safety() -> NSView {
        let thermal = NSPopUpButton()
        let levels = [(1, "Fair (earliest)"), (2, "Serious (default)"), (3, "Critical")]
        levels.forEach { thermal.addItem(withTitle: $0.1) }
        bind(thermal) { [unowned self] _ in self.commit { $0.thermalLimit = levels[max(0, thermal.indexOfSelectedItem)].0 } }
        loaders.append { c in thermal.selectItem(at: levels.firstIndex { $0.0 == c.thermalLimit } ?? 1) }

        return vstack([
            section("Battery", [form([
                ("Sleep below:", number("% on battery", 0...100, get: { Double($0.minBattery) }, set: { $0.minBattery = Int($1) })),
                ("Battery budget:", number("% per session (0 = unlimited)", 0...100, get: { Double($0.batteryBudget) }, set: { $0.batteryBudget = Int($1) })),
            ])]),
            section("Heat", [form([
                ("Warn at:", number("°C", 50...110, get: { $0.tempWarnC }, set: { $0.tempWarnC = $1 })),
                ("Sleep at:", number("°C", 50...115, get: { $0.tempLimitC }, set: { $0.tempLimitC = $1 })),
                ("Or at thermal pressure:", thermal),
            ])]),
            section("Backpack", [
                checkbox("Sleep when the lid is closed, on battery and the Mac warms up", \.backpackMode),
            ]),
            help("A safety stop puts the Mac to sleep and holds automatic triggers off for 30 minutes."),
        ], spacing: 20)
    }

    private func phone() -> NSView {
        let server = text(\.ntfyServer, placeholder: "https://ntfy.sh", normalize: { s in
            var s = s; while s.hasSuffix("/") { s.removeLast() }; return s
        }, valid: { s in URL(string: s).map { ($0.scheme == "https" || $0.scheme == "http") && $0.host != nil } ?? false })
        let topic = text(\.ntfyTopic, placeholder: "wakeful-…", valid: { s in
            !s.isEmpty && s.count <= 64 && s.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) && $0.isASCII || $0 == "-" || $0 == "_" }
        })
        let copy = button("Copy") { [unowned self] in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(self.config.ntfyTopic, forType: .string)
        }
        let webhook = text(\.haWebhook, placeholder: "https://homeassistant.local:8123/api/webhook/…",
                           valid: { s in s.isEmpty || URL(string: s).map { $0.scheme == "https" || $0.scheme == "http" } ?? false })
        let test = button("Send test notification") { Notifier.say("Wakeful test", "If you see this on your phone, notifications work.") }

        return vstack([
            section("ntfy", [
                checkbox("Send notifications to my phone", \.notifyPhone),
                checkbox("Accept commands from my phone (off · on 2h · status)", \.phoneCommands),
                form([("Server:", server), ("Topic:", hstack([topic, copy]))]),
                help("Subscribe to the topic in the ntfy app; send commands to <topic>-cmd. Keep it secret: anyone who knows it can read your notifications and send commands. A new topic means subscribing again."),
                test,
            ]),
            section("Webhook", [
                form([("Home Assistant:", webhook)]),
                help("Called with JSON on every on/off change. Leave empty to turn it off."),
            ]),
        ], spacing: 20)
    }

    private func schedules() -> NSView {
        scheduleStack.orientation = .vertical
        scheduleStack.alignment = .leading
        scheduleStack.spacing = 6
        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        scheduleStack.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(scheduleStack)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = doc
        scroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scroll.widthAnchor.constraint(equalToConstant: 590),
            scroll.heightAnchor.constraint(equalToConstant: 250),
            doc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            doc.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            scheduleStack.topAnchor.constraint(equalTo: doc.topAnchor),
            scheduleStack.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            scheduleStack.trailingAnchor.constraint(lessThanOrEqualTo: doc.trailingAnchor),
            scheduleStack.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
        ])
        loaders.append { [unowned self] c in
            self.scheduleRows.forEach { $0.view.removeFromSuperview() }
            self.scheduleRows = []
            c.schedules.forEach { self.addRow($0) }
            self.noSchedules.isHidden = !c.schedules.isEmpty
        }
        let add = button("Add schedule") { [unowned self] in
            self.addRow(Schedule(days: Array(1...7), start: "22:00", end: "07:00"))
            self.commitSchedules()
        }
        return vstack([
            help("Stay awake during these hours. An end before the start runs past midnight (the rule belongs to the day it starts); the same start and end means the whole day."),
            noSchedules,
            scroll,
            add,
        ], spacing: 10)
    }

    private func addRow(_ s: Schedule) {
        let row = ScheduleRow(s, onChange: { [unowned self] in self.commitSchedules() },
                              onRemove: { [unowned self] r in
                                  r.view.removeFromSuperview()
                                  self.scheduleRows.removeAll { $0 === r }
                                  self.commitSchedules()
                              })
        scheduleRows.append(row)
        scheduleStack.addArrangedSubview(row.view)
        noSchedules.isHidden = true
    }

    private func commitSchedules() {
        noSchedules.isHidden = !scheduleRows.isEmpty
        commit { $0.schedules = scheduleRows.map(\.schedule) }
    }

    // MARK: controls bound to a Config field

    private func bind(_ c: NSControl, _ fn: @escaping (Any) -> Void) {
        let a = Action(fn)
        actions.append(a)
        c.target = a
        c.action = #selector(Action.fire(_:))
    }

    private func button(_ title: String, _ fn: @escaping () -> Void) -> NSButton {
        let b = NSButton(title: title, target: nil, action: nil)
        bind(b) { _ in fn() }
        return b
    }

    private func checkbox(_ title: String, _ kp: WritableKeyPath<Config, Bool>) -> NSButton {
        let b = NSButton(checkboxWithTitle: title, target: nil, action: nil)
        bind(b) { [unowned self] _ in self.commit { $0[keyPath: kp] = b.state == .on } }
        loaders.append { b.state = $0[keyPath: kp] ? .on : .off }
        return b
    }

    /// Whole-number field + stepper, clamped to `range`.
    private func number(_ unit: String, _ range: ClosedRange<Double>, get: @escaping (Config) -> Double,
                        set: @escaping (inout Config, Double) -> Void) -> NSView {
        let f = NSTextField()
        f.alignment = .right
        f.widthAnchor.constraint(equalToConstant: 56).isActive = true
        let fmt = NumberFormatter()
        fmt.minimum = NSNumber(value: range.lowerBound)
        fmt.maximum = NSNumber(value: range.upperBound)
        fmt.maximumFractionDigits = 0
        fmt.usesGroupingSeparator = false
        f.formatter = fmt
        f.cell?.sendsActionOnEndEditing = true
        let s = NSStepper()
        s.minValue = range.lowerBound
        s.maxValue = range.upperBound
        s.increment = 1
        let apply = { [unowned self] (v: Double) in
            let v = min(max(v.rounded(), range.lowerBound), range.upperBound)
            f.doubleValue = v; s.doubleValue = v
            if v != get(self.config) { self.commit { set(&$0, v) } }
        }
        bind(f) { _ in apply(f.doubleValue) }
        bind(s) { _ in apply(s.doubleValue) }
        loaders.append { c in f.doubleValue = get(c); s.doubleValue = get(c) }
        return hstack([f, s, label(unit, secondary: true)], spacing: 4)
    }

    /// Text applied when editing ends; an invalid value beeps and puts the old one back.
    private func text(_ kp: WritableKeyPath<Config, String>, placeholder: String, normalize: @escaping (String) -> String = { $0 },
                      valid: @escaping (String) -> Bool) -> NSTextField {
        let f = NSTextField()
        f.placeholderString = placeholder
        f.widthAnchor.constraint(equalToConstant: 360).isActive = true
        f.cell?.sendsActionOnEndEditing = true
        bind(f) { [unowned self] _ in
            let v = normalize(f.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
            guard v != self.config[keyPath: kp] else { f.stringValue = v; return }
            if valid(v) { f.stringValue = v; self.commit { $0[keyPath: kp] = v } }
            else { NSSound.beep(); f.stringValue = self.config[keyPath: kp] }
        }
        loaders.append { f.stringValue = $0[keyPath: kp] }
        return f
    }
}

// MARK: - editable list of process names

final class StringListEditor: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let view: NSView
    private let table = NSTableView()
    private var items: [String] = []
    private let onChange: ([String]) -> Void
    private var actions: [Action] = []

    init(onChange: @escaping ([String]) -> Void) {
        self.onChange = onChange
        let scroll = NSScrollView()
        let stack = NSStackView()
        view = stack
        super.init()
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name")))
        table.headerView = nil
        table.usesAlternatingRowBackgroundColors = true
        table.rowHeight = 20
        table.dataSource = self
        table.delegate = self
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.widthAnchor.constraint(equalToConstant: 260).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: 170).isActive = true
        let add = tool(NSImage.addTemplateName) { [unowned self] in self.add() }
        let remove = tool(NSImage.removeTemplateName) { [unowned self] in self.remove() }
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.addArrangedSubview(scroll)
        stack.addArrangedSubview(hstack([add, remove], spacing: 0))
    }

    func set(_ v: [String]) { items = v; table.reloadData() }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let f = NSTextField(string: items[row])
        f.isBordered = false
        f.drawsBackground = false
        f.cell?.sendsActionOnEndEditing = true
        f.target = self
        f.action = #selector(edited(_:))
        return f
    }

    @objc private func edited(_ f: NSTextField) {
        let row = table.row(for: f)
        guard row >= 0, row < items.count else { return }
        let v = f.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if v.isEmpty { items.remove(at: row); table.reloadData() } else { items[row] = v }
        commit()
    }

    private func add() {
        table.window?.makeFirstResponder(nil)   // finish an edit in progress first
        items.append("")
        table.reloadData()
        let r = items.count - 1
        table.selectRowIndexes(IndexSet(integer: r), byExtendingSelection: false)
        table.editColumn(0, row: r, with: nil, select: true)   // an empty row left as is disappears again
    }

    private func remove() {
        table.window?.makeFirstResponder(nil)
        let r = table.selectedRow
        guard r >= 0, r < items.count else { NSSound.beep(); return }
        items.remove(at: r)
        table.reloadData()
        commit()
    }

    private func commit() {
        var seen = Set<String>()
        onChange(items.filter { !$0.isEmpty && seen.insert($0).inserted })
    }

    private func tool(_ image: NSImage.Name, _ fn: @escaping () -> Void) -> NSButton {
        let a = Action { _ in fn() }
        actions.append(a)
        let b = NSButton(image: NSImage(named: image)!, target: a, action: #selector(Action.fire(_:)))
        b.bezelStyle = .smallSquare
        b.widthAnchor.constraint(equalToConstant: 26).isActive = true
        return b
    }
}

// MARK: - one schedule: weekdays + start/end

final class ScheduleRow {
    let view: NSStackView
    private var days: [(Int, NSButton)] = []
    private let start: NSDatePicker, end: NSDatePicker
    private var actions: [Action] = []

    init(_ s: Schedule, onChange: @escaping () -> Void, onRemove: @escaping (ScheduleRow) -> Void) {
        start = ScheduleRow.picker(s.start)
        end = ScheduleRow.picker(s.end)
        view = NSStackView()
        let changed = Action { _ in onChange() }
        actions.append(changed)
        let cal = Calendar.current
        var views: [NSView] = []
        for i in 0..<7 {   // in the user's week order; stored as 1 = Sunday … 7 = Saturday
            let day = (cal.firstWeekday - 1 + i) % 7 + 1
            let b = NSButton(checkboxWithTitle: cal.shortWeekdaySymbols[day - 1], target: changed, action: #selector(Action.fire(_:)))
            b.state = s.days.contains(day) ? .on : .off
            days.append((day, b))
            views.append(b)
        }
        for p in [start, end] { p.target = changed; p.action = #selector(Action.fire(_:)) }
        let gone = Action { [unowned self] _ in onRemove(self) }
        actions.append(gone)
        let remove = NSButton(image: NSImage(named: NSImage.removeTemplateName)!, target: gone, action: #selector(Action.fire(_:)))
        remove.bezelStyle = .smallSquare
        views += [start, label("–"), end, remove]
        view.orientation = .horizontal
        view.alignment = .centerY
        view.spacing = 6
        views.forEach { view.addArrangedSubview($0) }
        view.setCustomSpacing(14, after: days.last!.1)
    }

    var schedule: Schedule {
        Schedule(days: days.filter { $0.1.state == .on }.map(\.0).sorted(), start: ScheduleRow.hhmm(start.dateValue), end: ScheduleRow.hhmm(end.dateValue))
    }

    private static func picker(_ hhmm: String) -> NSDatePicker {
        let p = NSDatePicker()
        p.datePickerStyle = .textFieldAndStepper
        p.datePickerElements = .hourMinute
        let parts = hhmm.split(separator: ":").compactMap { Int($0) }
        p.dateValue = parts.count == 2 ? Calendar.current.date(bySettingHour: parts[0], minute: parts[1], second: 0, of: Date()) ?? Date() : Date()
        return p
    }

    private static func hhmm(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }
}
