import Foundation
import AppKit

// MARK: - paths

enum Paths {
    static let dir: URL = {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Vigil")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()
    static let config = dir.appendingPathComponent("config.json")
    static let state = dir.appendingPathComponent("state.json")
    static let stats = dir.appendingPathComponent("stats.json")
    static let reports: URL = {
        let u = dir.appendingPathComponent("reports")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()
    static let hooks = dir.appendingPathComponent("hooks")
}

let dryRun = ProcessInfo.processInfo.environment["VIGIL_DRYRUN"] == "1"

// MARK: - shell

@discardableResult
func sh(_ path: String, _ args: [String] = [], timeout: TimeInterval = 8) -> (status: Int32, out: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch { return (-1, "\(error)") }
    let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    killer.cancel()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
}

// MARK: - config

struct Schedule: Codable {
    var days: [Int]          // 1 = Sunday … 7 = Saturday
    var start: String        // "22:00"
    var end: String          // "07:00"
}

struct Config: Codable {
    var theme = "eye"                         // eye | cat | robot
    var ntfyServer = "https://ntfy.sh"
    var ntfyTopic = "vigil-" + String((0..<24).map { _ in "abcdefghijklmnopqrstuvwxyz0123456789".randomElement()! })
    var notifyPhone = true
    var phoneCommands = true                  // listen on <topic>-cmd for off/on/status
    var haWebhook = ""                        // Home Assistant (or any) webhook, called on state changes
    var minBattery = 20                       // on battery, below this → sleep
    var batteryBudget = 0                     // max % of battery one session may use, 0 = unlimited
    var thermalLimit = 2                      // ProcessInfo.ThermalState raw value: 2 = serious
    var tempWarnC = 85.0
    var tempLimitC = 95.0
    var autoWatch = true                      // stay awake while agents / tasks are working
    var agents = ["claude", "codex", "aider", "gemini", "cursor-agent"]
    var tasks = ["rsync", "xcodebuild", "cargo", "brew", "ffmpeg", "tmutil"]
    var activityGraceMin = 10                 // an agent counts as working this long after its last activity
    var stuckMin = 15                         // watched process alive but silent this long → "probably stuck"
    var keepWhileRemote = true                // SSH / Screen Sharing session open → stay awake
    var onlyOnAC = false                      // automatic triggers only while plugged in
    var lockOnLidClose = true
    var displayOffOnLidClose = true
    var wifiKeepAlive = true
    var economyMode = true                    // Low Power Mode while awake with the lid closed on battery
    var backpackMode = true                   // lid closed + on battery + warming up → go to sleep
    var schedules: [Schedule] = []

    static func load() -> Config {
        if let d = try? Data(contentsOf: Paths.config), let c = try? JSONDecoder().decode(Config.self, from: d) { return c }
        let c = Config()
        c.save()
        return c
    }
    func save() {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? e.encode(self) { try? d.write(to: Paths.config) }
    }
}

// MARK: - notifications, webhooks, hooks

enum Notifier {
    static var config = Config.load()

    static func local(_ title: String, _ body: String) {
        let esc = { (s: String) in s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
        DispatchQueue.global().async {
            sh("/usr/bin/osascript", ["-e", "display notification \"\(esc(body))\" with title \"\(esc(title))\""])
        }
    }

    static func phone(_ title: String, _ body: String, priority: Int = 3, tags: String = "crescent_moon") {
        guard config.notifyPhone, let url = URL(string: "\(config.ntfyServer)/\(config.ntfyTopic)") else { return }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = "POST"
        req.httpBody = body.data(using: .utf8)
        req.setValue(title, forHTTPHeaderField: "Title")
        req.setValue(String(priority), forHTTPHeaderField: "Priority")
        req.setValue(tags, forHTTPHeaderField: "Tags")
        URLSession.shared.dataTask(with: req).resume()
    }

    static func say(_ title: String, _ body: String, priority: Int = 3, tags: String = "crescent_moon") {
        local(title, body)
        phone(title, body, priority: priority, tags: tags)
    }

    static func webhook(_ payload: [String: Any]) {
        guard !config.haWebhook.isEmpty, let url = URL(string: config.haWebhook),
              let body = try? JSONSerialization.data(withJSONObject: payload) else { return }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = "POST"
        req.httpBody = body
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        URLSession.shared.dataTask(with: req).resume()
    }

    /// Runs every executable in hooks/<event>.d with VIGIL_EVENT / VIGIL_REASON set.
    static func hooks(_ event: String, reason: String) {
        let dir = Paths.hooks.appendingPathComponent("\(event).d")
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        for f in files.sorted() where !f.hasPrefix(".") {
            let path = dir.appendingPathComponent(f).path
            guard FileManager.default.isExecutableFile(atPath: path) else { continue }
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: path)
                p.environment = ProcessInfo.processInfo.environment.merging(["VIGIL_EVENT": event, "VIGIL_REASON": reason]) { $1 }
                try? p.run()
            }
        }
    }
}

// MARK: - helpers

func fmtDuration(_ s: TimeInterval) -> String {
    let m = Int(s / 60)
    return m >= 60 ? "\(m / 60)h \(m % 60)m" : "\(m)m"
}

/// "2h", "90m", "1h30m", "45" (minutes) → seconds
func parseDuration(_ s: String) -> TimeInterval? {
    var total = 0.0, num = ""
    for ch in s.lowercased() {
        if ch.isNumber || ch == "." { num.append(ch); continue }
        guard let n = Double(num) else { return nil }
        num = ""
        switch ch {
        case "h": total += n * 3600
        case "m": total += n * 60
        case "d": total += n * 86400
        default: return nil
        }
    }
    if !num.isEmpty, let n = Double(num) { total += n * 60 }
    return total > 0 ? total : nil
}

/// "07:00" → next occurrence of that clock time
func nextTime(_ hhmm: String, from now: Date = Date()) -> Date? {
    let parts = hhmm.split(separator: ":").compactMap { Int($0) }
    guard parts.count == 2 else { return nil }
    return Calendar.current.nextDate(after: now, matching: DateComponents(hour: parts[0], minute: parts[1]), matchingPolicy: .nextTime)
}
