import Foundation
import ServiceManagement

// MARK: - launch at login

/// SMAppService on macOS 13+, a LaunchAgent plist (the same one install.sh writes) on 12 or when registering fails.
enum LaunchAtLogin {
    enum State { case on, off, needsApproval }

    static let agentPlist = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/LaunchAgents/app.wakeful.mac.plist")

    static var state: State {
        if #available(macOS 13, *) {
            switch SMAppService.mainApp.status {
            case .enabled: return .on
            case .requiresApproval: return .needsApproval
            default: break
            }
        }
        return FileManager.default.fileExists(atPath: agentPlist.path) ? .on : .off
    }

    static func openSystemSettings() {
        if #available(macOS 13, *) { SMAppService.openSystemSettingsLoginItems() }
    }

    /// nil on success, otherwise what went wrong.
    static func set(_ on: Bool) -> String? {
        if on {
            if #available(macOS 13, *) {
                // an ad-hoc signed app may be refused here: fall through to the LaunchAgent
                if (try? SMAppService.mainApp.register()) != nil { return nil }
            }
            return writeAgent()
        }
        if #available(macOS 13, *), SMAppService.mainApp.status != .notRegistered { try? SMAppService.mainApp.unregister() }
        // Only delete the file: `launchctl bootout` would kill this very process when launchd started it.
        // A plist that no longer exists simply isn't loaded at the next login.
        try? FileManager.default.removeItem(at: agentPlist)
        return state == .off ? nil : "Couldn't turn it off. Check System Settings › General › Login Items."
    }

    private static func writeAgent() -> String? {
        guard let exe = Bundle.main.executablePath else { return "Can't find the app's executable." }
        let plist: [String: Any] = [
            "Label": "app.wakeful.mac",
            "ProgramArguments": [exe],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
        ]
        do {
            try FileManager.default.createDirectory(at: agentPlist.deletingLastPathComponent(), withIntermediateDirectories: true)
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: agentPlist)
            return nil
        } catch { return "Couldn't write \(agentPlist.path): \(error.localizedDescription)" }
    }
}

// MARK: - update check (only when the user asks; nothing is downloaded or installed)

enum Updates {
    static let api = URL(string: "https://api.github.com/repos/faruksayfa3-commits/wakeful-mac/releases/latest")!
    static let releases = URL(string: "https://github.com/faruksayfa3-commits/wakeful-mac/releases")!

    enum Result { case newer(String, URL), upToDate(String), noRelease, failed(String) }

    static func check(_ done: @escaping (Result) -> Void) {
        var req = URLRequest(url: api, timeoutInterval: 15)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("Wakeful/\(appVersion)", forHTTPHeaderField: "User-Agent")   // GitHub rejects requests without one
        URLSession.shared.dataTask(with: req) { data, resp, err in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let r: Result
            if let err { r = .failed(err.localizedDescription) }
            else if code == 404 { r = .noRelease }
            else if code != 200 { r = .failed(code == 403 ? "GitHub rate limit, try again in an hour." : "GitHub answered HTTP \(code).") }
            else if let o = data.flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }),
                    let tag = o["tag_name"] as? String {
                let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
                let page = (o["html_url"] as? String).flatMap(URL.init(string:)) ?? releases
                r = isNewer(latest, than: appVersion) ? .newer(latest, page) : .upToDate(latest)
            } else { r = .failed("Unexpected answer from GitHub.") }
            DispatchQueue.main.async { done(r) }
        }.resume()
    }

    /// "1.10.0" > "1.9.2"; missing parts count as 0, a suffix such as "-beta" is ignored.
    static func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            (s.split(separator: "-").first ?? "").split(separator: ".").map { Int($0) ?? 0 }
        }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }
}
