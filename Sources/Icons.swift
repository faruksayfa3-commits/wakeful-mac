import AppKit

// Menu-bar glyphs drawn in code (18×18 design grid, template images → follow light/dark bar).
// Themes: eye (animated lid), cat, robot. Moods change the expression.

func themedIcon(theme: String, mood: Mood, t: CGFloat, size: CGFloat = 18) -> NSImage {
    let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
        let ctx = NSGraphicsContext.current!.cgContext
        ctx.scaleBy(x: size / 18, y: size / 18)
        NSColor.black.set()
        switch theme {
        case "cat": drawCat(mood)
        case "robot": drawRobot(mood)
        default: drawEye(mood, t: t)
        }
        return true
    }
    img.isTemplate = true
    img.accessibilityDescription = "Wakeful"
    return img
}

/// Eye lid position for each mood: 0 = open … 1 = closed.
func lid(for mood: Mood) -> CGFloat {
    switch mood {
    case .asleep: return 1
    case .tired: return 0.55
    default: return 0
    }
}

private func sweat(_ x: CGFloat, _ y: CGFloat) {
    let p = NSBezierPath()
    p.move(to: NSPoint(x: x, y: y + 2.4))
    p.curve(to: NSPoint(x: x, y: y), controlPoint1: NSPoint(x: x + 1.7, y: y + 0.6), controlPoint2: NSPoint(x: x + 1.3, y: y - 0.2))
    p.curve(to: NSPoint(x: x, y: y + 2.4), controlPoint1: NSPoint(x: x - 1.3, y: y - 0.2), controlPoint2: NSPoint(x: x - 1.7, y: y + 0.6))
    p.fill()
}

// MARK: eye

private func drawEye(_ mood: Mood, t: CGFloat) {
    let dy = 1.5 * t
    let left = NSPoint(x: 2, y: 9 + dy), right = NSPoint(x: 16, y: 9 + dy)
    let lowerCP = NSPoint(x: 9, y: 2 + dy)

    if mood == .happy {   // ^ ^ style: a single happy arc
        let p = NSBezierPath()
        p.lineWidth = 2; p.lineCapStyle = .round
        p.move(to: NSPoint(x: 2.5, y: 7))
        p.curve(to: NSPoint(x: 15.5, y: 7), controlPoint1: NSPoint(x: 5, y: 15), controlPoint2: NSPoint(x: 13, y: 15))
        p.stroke()
        return
    }

    let upperCP = NSPoint(x: 9, y: 16 - 14 * t + dy)
    let eye = NSBezierPath()
    eye.move(to: left)
    quad(eye, from: left, cp: upperCP, to: right)
    quad(eye, from: right, cp: lowerCP, to: left)
    eye.close()

    if t < 1 {
        NSGraphicsContext.saveGraphicsState()
        eye.addClip()
        let r: CGFloat = mood == .hot ? 2.0 : 2.8     // small pupil = alarmed
        NSBezierPath(ovalIn: NSRect(x: 9 - r, y: 9 + dy - r, width: r * 2, height: r * 2)).fill()
        NSGraphicsContext.restoreGraphicsState()
    }
    eye.lineWidth = 1.5
    eye.lineJoinStyle = .round
    eye.stroke()

    if t > 0.6 {
        let k = (t - 0.6) / 0.4
        let lashes = NSBezierPath()
        lashes.lineWidth = 1.3
        lashes.lineCapStyle = .round
        for s in [0.18, 0.34, 0.5, 0.66, 0.82] as [CGFloat] {
            let p = bez(left, lowerCP, right, s)
            let tx = 2 * (1 - s) * (lowerCP.x - left.x) + 2 * s * (right.x - lowerCP.x)
            let ty = 2 * (1 - s) * (lowerCP.y - left.y) + 2 * s * (right.y - lowerCP.y)
            let len = hypot(tx, ty)
            let n = NSPoint(x: ty / len, y: -tx / len)
            lashes.move(to: NSPoint(x: p.x + n.x * 0.5, y: p.y + n.y * 0.5))
            lashes.line(to: NSPoint(x: p.x + n.x * (0.5 + 2.6 * k), y: p.y + n.y * (0.5 + 2.6 * k)))
        }
        lashes.stroke()
    }
    if mood == .hot { sweat(15.6, 12.4) }
}

// MARK: cat / robot

private func faceEyes(_ centers: [NSPoint], _ mood: Mood, square: Bool = false) {
    for c in centers {
        switch mood {
        case .asleep:
            let p = NSBezierPath(); p.lineWidth = 1.3; p.lineCapStyle = .round
            p.move(to: NSPoint(x: c.x - 1.4, y: c.y + 0.4)); p.curve(to: NSPoint(x: c.x + 1.4, y: c.y + 0.4), controlPoint1: NSPoint(x: c.x - 0.6, y: c.y - 0.9), controlPoint2: NSPoint(x: c.x + 0.6, y: c.y - 0.9)); p.stroke()
        case .tired:
            let p = NSBezierPath(); p.lineWidth = 1.3; p.lineCapStyle = .round
            p.move(to: NSPoint(x: c.x - 1.5, y: c.y + 0.6)); p.line(to: NSPoint(x: c.x + 1.5, y: c.y + 0.6)); p.stroke()
            NSBezierPath(ovalIn: NSRect(x: c.x - 0.8, y: c.y - 1.2, width: 1.6, height: 0.9)).fill()
        case .happy:
            let p = NSBezierPath(); p.lineWidth = 1.4; p.lineCapStyle = .round
            p.move(to: NSPoint(x: c.x - 1.5, y: c.y - 0.6)); p.curve(to: NSPoint(x: c.x + 1.5, y: c.y - 0.6), controlPoint1: NSPoint(x: c.x - 0.7, y: c.y + 1.6), controlPoint2: NSPoint(x: c.x + 0.7, y: c.y + 1.6)); p.stroke()
        default:
            let r: CGFloat = mood == .hot ? 1.6 : 1.2
            let rect = NSRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
            (square ? NSBezierPath(rect: rect) : NSBezierPath(ovalIn: rect)).fill()
        }
    }
}

private func drawCat(_ mood: Mood) {
    let head = NSBezierPath()
    head.move(to: NSPoint(x: 3, y: 11.5))
    head.line(to: NSPoint(x: 3.6, y: 16.5)); head.line(to: NSPoint(x: 7.6, y: 13.4))
    head.curve(to: NSPoint(x: 10.4, y: 13.4), controlPoint1: NSPoint(x: 8.6, y: 13.7), controlPoint2: NSPoint(x: 9.4, y: 13.7))
    head.line(to: NSPoint(x: 14.4, y: 16.5)); head.line(to: NSPoint(x: 15, y: 11.5))
    head.curve(to: NSPoint(x: 9, y: 1.8), controlPoint1: NSPoint(x: 15.6, y: 5.5), controlPoint2: NSPoint(x: 13, y: 1.8))
    head.curve(to: NSPoint(x: 3, y: 11.5), controlPoint1: NSPoint(x: 5, y: 1.8), controlPoint2: NSPoint(x: 2.4, y: 5.5))
    head.close()
    head.lineWidth = 1.4; head.lineJoinStyle = .round; head.stroke()
    faceEyes([NSPoint(x: 6.2, y: 8), NSPoint(x: 11.8, y: 8)], mood)
    NSBezierPath(ovalIn: NSRect(x: 8.3, y: 5, width: 1.4, height: 1)).fill()
    if mood == .hot { sweat(16, 9) }
}

private func drawRobot(_ mood: Mood) {
    let head = NSBezierPath(roundedRect: NSRect(x: 2.5, y: 2.5, width: 13, height: 10), xRadius: 2.5, yRadius: 2.5)
    head.lineWidth = 1.4; head.stroke()
    let ant = NSBezierPath(); ant.lineWidth = 1.3; ant.lineCapStyle = .round
    ant.move(to: NSPoint(x: 9, y: 12.5)); ant.line(to: NSPoint(x: 9, y: 15)); ant.stroke()
    NSBezierPath(ovalIn: NSRect(x: 7.8, y: 15, width: 2.4, height: 2.4)).fill()
    faceEyes([NSPoint(x: 6, y: 8), NSPoint(x: 12, y: 8)], mood, square: true)
    let mouth = NSBezierPath(); mouth.lineWidth = 1.2; mouth.lineCapStyle = .round
    mouth.move(to: NSPoint(x: 6.5, y: 4.8)); mouth.line(to: NSPoint(x: 11.5, y: 4.8)); mouth.stroke()
    if mood == .hot { sweat(16.4, 10) }
}

// MARK: geometry

private func quad(_ path: NSBezierPath, from p0: NSPoint, cp: NSPoint, to p2: NSPoint) {
    path.curve(to: p2,
               controlPoint1: NSPoint(x: p0.x + 2 / 3 * (cp.x - p0.x), y: p0.y + 2 / 3 * (cp.y - p0.y)),
               controlPoint2: NSPoint(x: p2.x + 2 / 3 * (cp.x - p2.x), y: p2.y + 2 / 3 * (cp.y - p2.y)))
}

private func bez(_ p0: NSPoint, _ p1: NSPoint, _ p2: NSPoint, _ s: CGFloat) -> NSPoint {
    let a = (1 - s) * (1 - s), b = 2 * (1 - s) * s, c = s * s
    return NSPoint(x: a * p0.x + b * p1.x + c * p2.x, y: a * p0.y + b * p1.y + c * p2.y)
}
