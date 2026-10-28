import Foundation
import IOKit
import IOKit.ps

// MARK: - power

struct PowerInfo {
    var percent: Int
    var onAC: Bool
    var hasBattery: Bool
}

func readPower() -> PowerInfo {
    let snap = IOPSCopyPowerSourcesInfo().takeRetainedValue()
    let onAC = (IOPSGetProvidingPowerSourceType(snap).takeUnretainedValue() as String) != kIOPSBatteryPowerValue
    let list = IOPSCopyPowerSourcesList(snap).takeRetainedValue() as [CFTypeRef]
    for ps in list {
        guard let d = IOPSGetPowerSourceDescription(snap, ps)?.takeUnretainedValue() as? [String: Any],
              let cur = d[kIOPSCurrentCapacityKey] as? Int, let max = d[kIOPSMaxCapacityKey] as? Int, max > 0
        else { continue }
        return PowerInfo(percent: cur * 100 / max, onAC: onAC, hasBattery: true)
    }
    return PowerInfo(percent: 100, onAC: true, hasBattery: false)
}

// MARK: - lid, sleep flag

func lidClosed() -> Bool {
    let out = sh("/usr/sbin/ioreg", ["-r", "-k", "AppleClamshellState", "-d", "1"]).out
    return out.range(of: #"AppleClamshellState"\s*=\s*Yes"#, options: .regularExpression) != nil
}

func sleepDisabledNow() -> Bool {
    sh("/usr/bin/pmset", ["-g"]).out.range(of: #"SleepDisabled\s+1"#, options: .regularExpression) != nil
}

// MARK: - SMC (temperature / fan) — best effort, nil when a key does not exist

final class SMC {
    private struct KeyData {
        struct Vers { var major: UInt8 = 0, minor: UInt8 = 0, build: UInt8 = 0, reserved: UInt8 = 0, release: UInt16 = 0 }
        struct PLimit { var version: UInt16 = 0, length: UInt16 = 0, cpu: UInt32 = 0, gpu: UInt32 = 0, mem: UInt32 = 0 }
        struct Info { var size: UInt32 = 0, type: UInt32 = 0, attr: UInt8 = 0, pad0: UInt8 = 0, pad1: UInt8 = 0, pad2: UInt8 = 0 }
        var key: UInt32 = 0
        var vers = Vers()
        var pLimit = PLimit()
        var info = Info()
        var result: UInt8 = 0, status: UInt8 = 0, data8: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)
            = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    }

    private var conn: io_connect_t = 0
    static let shared = SMC()

    private init() {
        let svc = IOServiceGetMatchingService(kIOMainPortCompat, IOServiceMatching("AppleSMC"))
        if ProcessInfo.processInfo.environment["VIGIL_DEBUG"] != nil { print("smc svc", svc, "size", MemoryLayout<KeyData>.size) }
        guard svc != 0, MemoryLayout<KeyData>.size == 80 else { return }
        let r = IOServiceOpen(svc, mach_task_self_, 0, &conn)
        if ProcessInfo.processInfo.environment["VIGIL_DEBUG"] != nil { print("open", r) }
        IOObjectRelease(svc)
    }

    private func fourCC(_ s: String) -> UInt32 { s.utf8.reduce(0) { $0 << 8 | UInt32($1) } }

    private func call(_ input: inout KeyData) -> KeyData? {
        var out = KeyData()
        var size = MemoryLayout<KeyData>.size
        let r = IOConnectCallStructMethod(conn, 2, &input, MemoryLayout<KeyData>.size, &out, &size)
        return r == kIOReturnSuccess && out.result == 0 ? out : nil
    }

    func read(_ key: String) -> Double? {
        guard conn != 0 else { return nil }
        var q = KeyData()
        q.key = fourCC(key)
        q.data8 = 9
        guard let info = call(&q) else { return nil }
        q.info = info.info
        q.data8 = 5
        guard let r = call(&q) else { return nil }
        let b = withUnsafeBytes(of: r.bytes) { Array($0) }
        switch info.info.type {
        case fourCC("sp78"): return Double(Int16(bitPattern: UInt16(b[0]) << 8 | UInt16(b[1]))) / 256
        case fourCC("fpe2"): return Double(UInt16(b[0]) << 6 | UInt16(b[1]) >> 2)
        case fourCC("flt "): return Double(Float(bitPattern: UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24))
        default: return nil
        }
    }

    /// Hottest CPU/GPU/SoC temperature found. Intel keys first, then Apple Silicon ones.
    func temperature() -> Double? {
        let keys = ["TC0P", "TC0E", "TC0F", "TC0D", "TCXC", "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0H", "Tp0L", "Tg05", "Tg0D"]
        let v = keys.compactMap { read($0) }.filter { $0 > 5 && $0 < 130 }
        return v.max()
    }

    func fanRPM() -> Double? { read("F0Ac") }
}

private let kIOMainPortCompat: mach_port_t = 0   // == kIOMasterPortDefault / kIOMainPortDefault

// MARK: - processes

struct Proc {
    var pid: Int32, ppid: Int32
    var cpu: Double
    var path: String
    var name: String { (path as NSString).lastPathComponent }
}

func listProcesses() -> [Proc] {
    let out = sh("/bin/ps", ["-Ao", "pid=,ppid=,pcpu=,comm="]).out
    var res: [Proc] = []
    for line in out.split(separator: "\n") {
        let f = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
        guard f.count == 4, let pid = Int32(f[0]), let ppid = Int32(f[1]), let cpu = Double(f[2]) else { continue }
        res.append(Proc(pid: pid, ppid: ppid, cpu: cpu, path: String(f[3])))
    }
    return res
}

func matches(_ p: Proc, _ name: String) -> Bool {
    let n = name.lowercased()
    return p.name.lowercased() == n || p.path.lowercased().contains("/\(n)/")
}

func descendants(of root: Int32, in all: [Proc]) -> [Proc] {
    var result: [Proc] = [], frontier: [Int32] = [root]
    while let cur = frontier.popLast() {
        for p in all where p.ppid == cur { result.append(p); frontier.append(p.pid) }
    }
    return result
}

/// Remote sessions: SSH logins, Screen Sharing, or a remote-desktop app streaming (CPU heuristic).
func remoteSessionActive(_ procs: [Proc]) -> String? {
    let who = sh("/usr/bin/who").out.split(separator: "\n").filter { $0.contains("(") && !$0.contains("(:") }
    if !who.isEmpty { return "ssh" }
    if procs.contains(where: { $0.name == "screensharingd" && $0.cpu > 1 }) { return "screen sharing" }
    for app in ["AnyDesk", "rustdesk", "TeamViewer"] where procs.contains(where: { $0.name.lowercased() == app.lowercased() && $0.cpu > 8 }) {
        return app
    }
    return nil
}

func totalCPUPercent(_ procs: [Proc]) -> Double {
    procs.reduce(0) { $0 + $1.cpu } / Double(ProcessInfo.processInfo.activeProcessorCount)
}

func wifiGateway() -> String? {
    let out = sh("/sbin/route", ["-n", "get", "default"]).out
    for l in out.split(separator: "\n") where l.contains("gateway:") {
        return l.split(separator: ":").last.map { $0.trimmingCharacters(in: .whitespaces) }
    }
    return nil
}
