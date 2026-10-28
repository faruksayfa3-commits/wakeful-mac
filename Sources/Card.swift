import AppKit

/// 1080×1920 shareable "night card" (for stories / TikTok), drawn with CoreGraphics only.
enum Card {
    static func render(_ s: SessionLog, duration: TimeInterval, endPercent: Int, score: Int, streak: Int, to path: String) -> Bool {
        let size = NSSize(width: 1080, height: 1920)
        let img = NSImage(size: size, flipped: false) { rect in
            NSGradient(colors: [NSColor(red: 0.05, green: 0.06, blue: 0.16, alpha: 1), NSColor(red: 0.20, green: 0.10, blue: 0.38, alpha: 1)])!
                .draw(in: rect, angle: 90)
            // stars
            var rng = SeededRNG(seed: UInt64(s.start.timeIntervalSince1970))
            for _ in 0..<70 {
                let r = CGFloat.random(in: 1.5...4, using: &rng)
                NSColor.white.withAlphaComponent(CGFloat.random(in: 0.2...0.8, using: &rng)).setFill()
                NSBezierPath(ovalIn: NSRect(x: CGFloat.random(in: 0...1080, using: &rng), y: CGFloat.random(in: 700...1920, using: &rng), width: r, height: r)).fill()
            }
            // big eye, tinted white
            let eye = themedIcon(theme: "eye", mood: .awake, t: 0, size: 360)
            let tinted = NSImage(size: eye.size)
            tinted.lockFocus()
            eye.draw(in: NSRect(origin: .zero, size: eye.size))
            NSColor.white.set()
            NSRect(origin: .zero, size: eye.size).fill(using: .sourceAtop)
            tinted.unlockFocus()
            tinted.draw(in: NSRect(x: 360, y: 1330, width: 360, height: 360))

            // `top` = y of the line's top edge, measured from the bottom of the canvas
            func text(_ t: String, top: CGFloat, size: CGFloat, weight: NSFont.Weight = .bold, color: NSColor = .white, alpha: CGFloat = 1, lines: CGFloat = 1) {
                let p = NSMutableParagraphStyle(); p.alignment = .center
                let a: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight),
                                                         .foregroundColor: color.withAlphaComponent(alpha), .paragraphStyle: p]
                let h = size * 1.25 * lines
                NSString(string: t).draw(in: NSRect(x: 60, y: top - h, width: 960, height: h), withAttributes: a)
            }
            text("While I slept,\nmy Mac worked", top: 1290, size: 66, weight: .medium, alpha: 0.8, lines: 2)
            text(fmtDuration(duration), top: 1090, size: 200, weight: .heavy)
            var y: CGFloat = 790
            let used = max(0, s.startPercent - endPercent)
            var lines = ["battery \(s.startPercent)% → \(endPercent)%  (−\(used)%)"]
            if s.maxTemp > 0 { lines.append("peak \(Int(s.maxTemp))°C") }
            if !s.finished.isEmpty { lines.append("finished: " + s.finished.prefix(3).joined(separator: ", ")) }
            if let top = s.procSeconds.max(by: { $0.value < $1.value }) { lines.append("kept awake for \(top.key) · \(fmtDuration(top.value))") }
            for l in lines { text(l, top: y, size: 48, weight: .medium, alpha: 0.9); y -= 84 }
            text("night score \(score)/100", top: 400, size: 84, weight: .heavy, color: NSColor(red: 1, green: 0.85, blue: 0.4, alpha: 1))
            if streak > 1 { text("\(streak)-night streak", top: 285, size: 54, weight: .semibold, alpha: 0.85) }
            text("Wakeful — open-source, keeps your Mac awake", top: 140, size: 36, weight: .medium, alpha: 0.55)
            return true
        }
        guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: URL(fileURLWithPath: path))) != nil
    }
}

struct SeededRNG: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
