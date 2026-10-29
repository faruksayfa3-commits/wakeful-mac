import Foundation
import AppKit

enum Mood: String { case asleep, awake, tired, hot, happy }

struct SessionLog {
    var start = Date()
    var startPercent = 100
    var minPercent = 100
    var maxTemp = 0.0
    var reasons = Set<String>()
    var procSeconds: [String: TimeInterval] = [:]
    var finished: [String] = []
    var trips: [String] = []
    var stuck: [String] = []
    var lidSeconds = 0.0
    var remoteSeconds = 0.0
}

final class Engine {
    static let tickSeconds: TimeInterval = 10
    static let remoteHoldOff: TimeInterval = 60

    var config = Config.load() { didSet { Notifier.config = config } }
    var onChange: (() -> Void)?

    // manual control
    private(set) var manualOn = false
    private(set) var manualEnd: Date?
    private(set) var manualWatch: String?
    private var manualWatchSeen = false
    private var manualStarted = Date()

    // automatic state
    private var blockedUntil: Date?
    private var lastActivity: [String: Date] = [:]
    private var lastBusy: [String: Date] = [:]   // last tick a watched process used CPU, agents and tasks alike (stuck detector)
    private var remoteSeen: (kind: String, at: Date)?
    private var present: [String: Bool] = [:]
    private var stuckNotified = Set<String>()
    private var lastWarn = Date.distantPast
    private var lastDust = Date.distantPast
    private var warmSince: Date?
    private var fakeAwake = false
    private var weSetLowPower = false
    private var lastLid = false
    private(set) var session: SessionLog?
    private(set) var mood: Mood = .asleep
    private(set) var reasons: [String] = []
    private(set) var power = readPower()
    private(set) var tempC: Double?
    private(set) var lid = false
    private(set) var externalAwake = false
    private var happyUntil = Date.distantPast
    private var timer: Timer?
    private var wifiBusy = false
    private var restorePending = false   // we set disablesleep=1 and have not managed to set it back yet
    private var sleepFailNotified = false   // one "can't change sleep settings" per episode, not one per tick

    var awake: Bool { dryRun ? fakeAwake : sleepDisabledNow() }

    func start() {
        Notifier.config = config
        // A previous run killed mid-session left disablesleep=1 behind: that flag is ours, not "another tool's".
        if !dryRun, let d = try? Data(contentsOf: Paths.state),
           let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
           o["since"] != nil, o["dryRun"] as? Bool != true, sleepDisabledNow() { restorePending = true }
        timer = Timer.scheduledTimer(withTimeInterval: Engine.tickSeconds, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer!, forMode: .common)
        tick()
    }

    // MARK: commands (UI, URL scheme, phone)

    func startManual(duration: TimeInterval?, until: Date? = nil, watch: String? = nil) {
        manualOn = true
        manualStarted = Date()
        manualEnd = until ?? duration.map { Date().addingTimeInterval($0) }
        manualWatch = watch
        manualWatchSeen = false
        blockedUntil = nil
        tick()
    }

    func stopManual() {
        manualOn = false
        manualEnd = nil
        manualWatch = nil
        blockedUntil = Date().addingTimeInterval(60)   // a manual "off" wins over automatic triggers for a minute
        tick()
    }

    // MARK: main loop

    func tick() {
        let now = Date()
        let procs = listProcesses()
        power = readPower()
        lid = lidClosed()
        tempC = SMC.shared.temperature()
        let thermal = ProcessInfo.processInfo.thermalState.rawValue
        let isAwake = awake
        let cpu = totalCPUPercent(procs)
        // remote detection is a CPU heuristic that flickers around its thresholds: a session only counts as
        // ended after 60 s without a sighting, otherwise it starts and stops an awake session every tick
        if let r = remoteSessionActive(procs) { remoteSeen = (r, now) }
        else if let r = remoteSeen, now.timeIntervalSince(r.at) >= Engine.remoteHoldOff { remoteSeen = nil }
        let remote = remoteSeen?.kind

        // ---- reasons to stay awake ----
        var why: [String] = []
        var procActive: [String: Bool] = [:]

        if manualOn {
            if let end = manualEnd, end <= now {
                manualOn = false; manualEnd = nil
            } else if let w = manualWatch {
                let alive = procs.contains { matches($0, w) || String($0.pid) == w }
                if alive { manualWatchSeen = true }
                if !alive && (manualWatchSeen || now.timeIntervalSince(manualStarted) > 90) {
                    manualOn = false; manualWatch = nil
                    if manualWatchSeen { finishedTask(w) }
                } else { why.append("watch:\(w)"); procActive[w] = true }
            } else { why.append("manual") }
        }

        let acOK = !config.onlyOnAC || power.onAC
        if acOK, scheduleActive(now) { why.append("schedule") }

        if acOK && config.autoWatch {
            for name in config.agents + config.tasks {
                let isAgent = config.agents.contains(name)
                let mine = procs.filter { matches($0, name) }
                let exists = !mine.isEmpty
                if exists {
                    let family = mine + mine.flatMap { descendants(of: $0.pid, in: procs) }
                    let busy = family.reduce(0) { $0 + $1.cpu } > (isAgent ? 2.0 : 0.5)
                    if busy || !isAgent { lastActivity[name] = now }
                    else if lastActivity[name] == nil { lastActivity[name] = now }
                    // tasks keep the Mac awake while they exist, so "stuck" is measured on CPU, not on lastActivity
                    if busy || lastBusy[name] == nil { lastBusy[name] = now }
                    let idle = now.timeIntervalSince(lastActivity[name] ?? now)
                    if isAgent ? idle < Double(config.activityGraceMin) * 60 : true {
                        why.append(isAgent ? "agent:\(name)" : "task:\(name)")
                        procActive[name] = true
                    }
                    let silent = now.timeIntervalSince(lastBusy[name] ?? now)
                    if silent > Double(config.stuckMin) * 60, !stuckNotified.contains(name), session != nil {
                        stuckNotified.insert(name)
                        session?.stuck.append(name)
                        Notifier.say("Wakeful: \(name) looks stuck", "\(name) is alive but has done nothing for \(config.stuckMin) minutes.", priority: 4, tags: "warning")
                    }
                    if busy { stuckNotified.remove(name) }
                }
                if present[name] == true && !exists && !isAgent { finishedTask(name) }
                if !exists {   // a later run of the same tool starts with a clean slate
                    lastActivity[name] = nil; lastBusy[name] = nil; stuckNotified.remove(name)
                }
                present[name] = exists
            }
        }

        if config.keepWhileRemote, acOK || manualOn, let r = remote { why.append("remote:\(r)") }

        reasons = why
        externalAwake = isAwake && session == nil && !restorePending

        // ---- guards ----
        var trip: String?
        let owned = session != nil
        if owned || !why.isEmpty {
            if !power.onAC && power.percent < config.minBattery { trip = "battery at \(power.percent)%" }
            else if config.batteryBudget > 0, !power.onAC, let s = session, s.startPercent - power.percent >= config.batteryBudget {
                trip = "battery budget of \(config.batteryBudget)% used"
            }
            else if thermal >= config.thermalLimit || (tempC ?? 0) >= config.tempLimitC { trip = "too hot (\(tempC.map { "\(Int($0))°C" } ?? "thermal pressure"))" }
            else if config.backpackMode, lid, !power.onAC, thermal >= 1 || (tempC ?? 0) >= config.tempWarnC, remote == nil {
                trip = "backpack mode: lid closed, on battery and warming up"
            }
        }

        if let t = (tempC ?? 0) >= config.tempWarnC ? tempC : nil, trip == nil, now.timeIntervalSince(lastWarn) > 600, owned {
            lastWarn = now
            Notifier.say("Wakeful: Mac is hot", "\(Int(t))°C — I'll put it to sleep at \(Int(config.tempLimitC))°C.", priority: 4, tags: "fire")
        }
        // hot while barely working → fan blocked / dust
        if let t = tempC, t >= config.tempWarnC - 5, cpu < 30 {
            warmSince = warmSince ?? now
            if now.timeIntervalSince(warmSince!) > 300, now.timeIntervalSince(lastDust) > 6 * 3600 {
                lastDust = now
                Notifier.say("Wakeful: check the fan", "\(Int(t))°C at only \(Int(cpu))% CPU for 5+ minutes — dust or a blocked vent is likely.", priority: 3, tags: "wind_face")
            }
        } else { warmSince = nil }

        if let trip {
            let wasBlocked = (blockedUntil ?? .distantPast) > now
            if isAwake && owned { _ = setSleepDisabled(false) }
            session?.trips.append(trip)   // before endSession, which clears `session`
            if owned { endSession(reason: "guard: \(trip)") }
            if owned || !wasBlocked {   // once per episode, not on every tick while the condition lasts
                Notifier.say("Wakeful: going to sleep", trip, priority: 5, tags: "rotating_light")
                Notifier.hooks("guard", reason: trip)
            }
            blockedUntil = now.addingTimeInterval(1800)
            manualOn = false; manualEnd = nil; manualWatch = nil
        }

        // ---- switch on / off ----
        let blocked = (blockedUntil ?? .distantPast) > now
        let want = !why.isEmpty && !blocked && trip == nil
        if !want && !restorePending { sleepFailNotified = false }   // the episode is over: a new one may warn again
        let nowAwake = awake
        if want && !nowAwake && !externalAwake {
            if setSleepDisabled(true) { beginSession(reasons: why) }
        } else if want && nowAwake && session == nil && !externalAwake {
            beginSession(reasons: why)
        } else if !want && session != nil {
            if nowAwake { _ = setSleepDisabled(false) }
            endSession(reason: why.isEmpty ? "nothing left to wait for" : "blocked")
        } else if !want && restorePending {   // an earlier "back to normal sleep" failed: retry
            if nowAwake { _ = setSleepDisabled(false) } else { restorePending = false }
        }

        // ---- while a session runs ----
        if session != nil {
            let dt = Engine.tickSeconds
            session!.minPercent = min(session!.minPercent, power.percent)
            session!.maxTemp = max(session!.maxTemp, tempC ?? 0)
            session!.reasons.formUnion(why.map { $0.components(separatedBy: ":").first! })
            for (n, a) in procActive where a { session!.procSeconds[n, default: 0] += dt }
            if lid { session!.lidSeconds += dt }
            if why.contains(where: { $0.hasPrefix("remote") }) { session!.remoteSeconds += dt }
            lidActions(closedNow: lid)
            if lid && config.wifiKeepAlive { keepWiFi() }
        } else if weSetLowPower { setLowPower(false) }
        lastLid = lid

        // ---- mood + state file ----
        let sessionOn = session != nil || externalAwake
        if !sessionOn { mood = now < happyUntil ? .happy : .asleep }
        else if (tempC ?? 0) >= config.tempWarnC || thermal >= 2 { mood = .hot }
        else if !power.onAC && power.percent < 35 { mood = .tired }
        else { mood = .awake }
        writeState()
        onChange?()
    }

    // MARK: schedule

    private func scheduleActive(_ now: Date) -> Bool {
        let cal = Calendar.current
        let wd = cal.component(.weekday, from: now)
        let minutes = cal.component(.hour, from: now) * 60 + cal.component(.minute, from: now)
        func mins(_ s: String) -> Int? { let p = s.split(separator: ":").compactMap { Int($0) }; return p.count == 2 ? p[0] * 60 + p[1] : nil }
        for r in config.schedules {
            guard let a = mins(r.start), let b = mins(r.end) else { continue }
            if a == b { if r.days.contains(wd) { return true } }   // start == end: the whole day
            else if a < b { if r.days.contains(wd) && minutes >= a && minutes < b { return true } }
            else {   // crosses midnight: the rule's day is the day it starts
                let prev = wd == 1 ? 7 : wd - 1
                if (r.days.contains(wd) && minutes >= a) || (r.days.contains(prev) && minutes < b) { return true }
            }
        }
        return false
    }

    // MARK: session lifecycle

    private func beginSession(reasons: [String]) {
        var s = SessionLog()
        s.startPercent = power.percent
        s.minPercent = power.percent
        s.reasons = Set(reasons.map { $0.components(separatedBy: ":").first! })
        session = s
        stuckNotified = []
        let desc = reasons.joined(separator: ", ")
        Notifier.phone("Wakeful is awake", "Staying awake: \(desc)", priority: 2, tags: "eyes")
        Notifier.hooks("on", reason: desc)
        Notifier.webhook(["state": "on", "reasons": reasons, "battery": power.percent])
    }

    private func endSession(reason: String) {
        guard let s = session else { return }
        session = nil
        setLowPower(false)
        let report = Report.build(s, end: Date(), endPercent: power.percent, reason: reason)
        Notifier.say("Wakeful is done", report.summary, priority: 3, tags: "sleeping")
        Notifier.hooks("off", reason: reason)
        Notifier.webhook(["state": "off", "reason": reason, "battery": power.percent])
        if s.trips.isEmpty { happyUntil = Date().addingTimeInterval(120) }
    }

    private func finishedTask(_ name: String) {
        session?.finished.append(name)
        Notifier.say("Wakeful: \(name) finished", "\(name) is done" + (session.map { " after \(fmtDuration(Date().timeIntervalSince($0.start))) awake" } ?? "") + ".", priority: 3, tags: "white_check_mark")
        Notifier.hooks("finished", reason: name)
    }

    // MARK: lid / system actions

    private func lidActions(closedNow: Bool) {
        if closedNow && !lastLid {
            if config.lockOnLidClose { lockScreen() }
            if config.displayOffOnLidClose { sh("/usr/bin/pmset", ["displaysleepnow"]) }
            if config.economyMode && !power.onAC { setLowPower(true) }
        } else if !closedNow && lastLid {
            setLowPower(false)
        }
    }

    private func keepWiFi() {
        guard !wifiBusy, let gw = wifiGateway() else { return }
        wifiBusy = true
        DispatchQueue.global().async { [weak self] in
            sh("/sbin/ping", ["-c", "1", "-t", "2", gw])
            DispatchQueue.main.async { self?.wifiBusy = false }
        }
    }

    private func setLowPower(_ on: Bool) {
        guard on != weSetLowPower, !dryRun else { return }
        if sh("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "-a", "lowpowermode", on ? "1" : "0"]).status == 0 { weSetLowPower = on }
    }

    func setSleepDisabled(_ value: Bool) -> Bool {
        if dryRun { fakeAwake = value; return true }
        let r = sh("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "-a", "disablesleep", value ? "1" : "0"])
        if r.status == 0 { sleepFailNotified = false }
        else if !sleepFailNotified {   // a missing sudoers rule fails on every tick: say it once
            sleepFailNotified = true
            Notifier.local("Wakeful can't change sleep settings", "The sudoers rule is missing. Open Health check… in the Wakeful menu for the fix.")
        }
        restorePending = !value && r.status != 0
        return r.status == 0
    }

    /// On quit / SIGTERM: give disablesleep back if we hold it.
    func shutdown() {
        if session != nil || restorePending, awake { _ = setSleepDisabled(false) }
    }

    // MARK: state file (read by the `wakeful` CLI)

    private func writeState() {
        var d: [String: Any] = [
            "awake": awake, "mood": mood.rawValue, "reasons": reasons, "lidClosed": lid,
            "battery": power.percent, "onAC": power.onAC, "external": externalAwake,
            "theme": config.theme, "phoneTopic": config.ntfyTopic, "dryRun": dryRun,
        ]
        if let t = tempC { d["tempC"] = Int(t) }
        if let s = session { d["since"] = ISO8601DateFormatter().string(from: s.start); d["awakeSeconds"] = Int(Date().timeIntervalSince(s.start)) }
        if let e = manualEnd { d["until"] = ISO8601DateFormatter().string(from: e) }
        if let data = try? JSONSerialization.data(withJSONObject: d, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: Paths.state) }
    }

    func statusLine() -> String {
        if externalAwake { return "Awake (set by another tool)" }
        guard let s = session else { return "Asleep — normal sleep" }
        let for_ = fmtDuration(Date().timeIntervalSince(s.start))
        var line = "Awake for \(for_)"
        if let e = manualEnd { line += " · until \(DateFormatter.localizedString(from: e, dateStyle: .none, timeStyle: .short))" }
        if let first = reasons.first { line += " · \(first.replacingOccurrences(of: ":", with: " "))" }
        return line
    }
}

// MARK: - lock screen (private login.framework call, no permissions needed)

func lockScreen() {
    guard !dryRun, let h = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_LAZY),
          let sym = dlsym(h, "SACLockScreenImmediate") else { return }
    typealias Fn = @convention(c) () -> Int32
    _ = unsafeBitCast(sym, to: Fn.self)()
}
