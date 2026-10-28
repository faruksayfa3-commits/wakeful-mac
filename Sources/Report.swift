import Foundation
import AppKit

struct Stats: Codable {
    var totalSeconds = 0.0
    var sessions = 0
    var finishedTasks = 0
    var nights: [String] = []      // yyyy-MM-dd of every "night" (≥2h awake overlapping 00:00–05:00)

    static func load() -> Stats {
        (try? Data(contentsOf: Paths.stats)).flatMap { try? JSONDecoder().decode(Stats.self, from: $0) } ?? Stats()
    }
    func save() { if let d = try? JSONEncoder().encode(self) { try? d.write(to: Paths.stats) } }

    var streak: Int {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        let set = Set(nights)
        var day = Date(), n = 0
        if !set.contains(f.string(from: day)) { day = Calendar.current.date(byAdding: .day, value: -1, to: day)! }
        while set.contains(f.string(from: day)) { n += 1; day = Calendar.current.date(byAdding: .day, value: -1, to: day)! }
        return n
    }
}

enum Report {
    struct Result { var summary: String; var markdown: String; var score: Int; var cardPath: String? }

    static func score(_ s: SessionLog, hours: Double) -> Int {
        min(100, Int(hours * 9) + s.finished.count * 8 + (s.trips.isEmpty ? 10 : 0) + (s.stuck.isEmpty ? 5 : 0))
    }

    @discardableResult
    static func build(_ s: SessionLog, end: Date, endPercent: Int, reason: String) -> Result {
        let dur = end.timeIntervalSince(s.start)
        let hours = dur / 3600
        let used = max(0, s.startPercent - endPercent)
        let sc = score(s, hours: hours)

        // stats + streak
        var st = Stats.load()
        st.totalSeconds += dur; st.sessions += 1; st.finishedTasks += s.finished.count
        if dur >= 7200, overlapsNight(s.start, end) {
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
            let key = f.string(from: end)
            if !st.nights.contains(key) { st.nights.append(key) }
        }
        st.save()

        var md = "# Vigil — night report\n\n"
        md += "- Awake: **\(fmtDuration(dur))** (\(time(s.start)) → \(time(end)))\n"
        md += "- Why: \(s.reasons.sorted().joined(separator: ", "))\n"
        md += "- Battery: \(s.startPercent)% → \(endPercent)% (used \(used)%)\n"
        if s.maxTemp > 0 { md += "- Hottest: \(Int(s.maxTemp))°C\n" }
        if s.lidSeconds > 0 { md += "- Lid closed for \(fmtDuration(s.lidSeconds))\n" }
        if s.remoteSeconds > 0 { md += "- Remote session open for \(fmtDuration(s.remoteSeconds))\n" }
        if !s.procSeconds.isEmpty {
            md += "\n## What I kept awake\n"
            for (n, secs) in s.procSeconds.sorted(by: { $0.value > $1.value }) { md += "- \(n): \(fmtDuration(secs))\n" }
        }
        if !s.finished.isEmpty { md += "\n## Finished\n" + s.finished.map { "- \($0)\n" }.joined() }
        if !s.stuck.isEmpty { md += "\n## Looked stuck\n" + s.stuck.map { "- \($0)\n" }.joined() }
        if !s.trips.isEmpty { md += "\n## Safety stops\n" + s.trips.map { "- \($0)\n" }.joined() }
        md += "\nNight score: **\(sc)/100** · streak: \(st.streak) night(s) · ended because: \(reason)\n"

        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd_HHmm"
        let base = Paths.reports.appendingPathComponent("night-\(f.string(from: s.start))")
        try? md.write(to: base.appendingPathExtension("md"), atomically: true, encoding: .utf8)

        var card: String?
        if dur >= 600 {
            let path = base.appendingPathExtension("png").path
            if Card.render(s, duration: dur, endPercent: endPercent, score: sc, streak: st.streak, to: path) { card = path }
        }

        let summary = "\(fmtDuration(dur)) awake, battery \(s.startPercent)%→\(endPercent)%"
            + (s.finished.isEmpty ? "" : ", finished: \(s.finished.joined(separator: ", "))")
            + (s.maxTemp > 0 ? ", max \(Int(s.maxTemp))°C" : "")
            + ", score \(sc)/100"
        return Result(summary: summary, markdown: md, score: sc, cardPath: card)
    }

    private static func time(_ d: Date) -> String { DateFormatter.localizedString(from: d, dateStyle: .none, timeStyle: .short) }

    private static func overlapsNight(_ a: Date, _ b: Date) -> Bool {
        let cal = Calendar.current
        var day = cal.startOfDay(for: a)
        while day <= b {
            let from = cal.date(byAdding: .hour, value: 0, to: day)!, to = cal.date(byAdding: .hour, value: 5, to: day)!
            if a < to && b > from { return true }
            day = cal.date(byAdding: .day, value: 1, to: day)!
        }
        return false
    }
}
