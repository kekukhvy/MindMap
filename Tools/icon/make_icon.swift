import AppKit

// Usage: swift Tools/icon/make_icon.swift <Assets.xcassets dir> [preview.png]
// Style matches LifePay's icon (teal-green gradient, white shapes, mac squircle with margin + shadow).
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let set = root.appendingPathComponent("AppIcon.appiconset")
try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)

func draw(_ px: Int, rounded: Bool) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let inset = rounded ? s * 0.098 : 0
    let rect = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let radius = rounded ? rect.width * 0.2237 : 0
    let shape = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    if rounded {
        let sh = NSShadow()
        sh.shadowColor = NSColor.black.withAlphaComponent(0.3)
        sh.shadowBlurRadius = s * 0.02
        sh.shadowOffset = NSSize(width: 0, height: -s * 0.01)
        NSGraphicsContext.saveGraphicsState(); sh.set(); NSColor.black.setFill(); shape.fill()
        NSGraphicsContext.restoreGraphicsState()
    }
    NSGradient(colors: [NSColor(red: 0.10, green: 0.62, blue: 0.40, alpha: 1),
                        NSColor(red: 0.04, green: 0.32, blue: 0.30, alpha: 1)])!
        .draw(in: shape, angle: -60)
    shape.addClip()

    let w = rect.width
    // Unit coords: (0,0) top-left of the icon shape, y down.
    func P(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: rect.minX + x * w, y: rect.maxY - y * w) }
    func pill(cx: CGFloat, cy: CGFloat, w pw: CGFloat, h ph: CGFloat) -> NSRect {
        NSRect(x: rect.minX + (cx - pw / 2) * w, y: rect.maxY - (cy + ph / 2) * w, width: pw * w, height: ph * w)
    }
    let white = NSColor(red: 0.925, green: 0.953, blue: 0.957, alpha: 1)
    let yellow = NSColor(red: 1.0, green: 0.80, blue: 0.25, alpha: 1)

    // Root topic and the branch endpoints (branches 1-3 end in topics, 4 runs off the edge).
    let rootR = pill(cx: 0.37, cy: 0.52, w: 0.30, h: 0.22)
    let rx = 0.37 + 0.15, ry: CGFloat = 0.52
    let targets: [(x: CGFloat, y: CGFloat, w: CGFloat, color: NSColor)] = [
        (0.76, 0.22, 0.26, white), (0.90, 0.52, 0.30, yellow), (0.76, 0.82, 0.26, white)]

    func branch(_ a: NSPoint, _ b: NSPoint) {
        let p = NSBezierPath()
        p.move(to: a)
        let dx = (b.x - a.x) * 0.55
        p.curve(to: b, controlPoint1: NSPoint(x: a.x + dx, y: a.y), controlPoint2: NSPoint(x: b.x - dx, y: b.y))
        p.lineWidth = w * 0.045; p.lineCapStyle = .round
        white.setStroke(); p.stroke()
    }
    for t in targets { branch(P(rx - 0.06, ry), P(t.x - t.w / 2 + 0.05, t.y)) }
    // Left branch leaving the icon: "a piece of a bigger map".
    do {
        let a = P(0.37 - 0.15 + 0.06, 0.52), b = P(-0.08, 0.80)
        let p = NSBezierPath(); p.move(to: a)
        p.curve(to: b, controlPoint1: NSPoint(x: a.x - w * 0.12, y: a.y), controlPoint2: NSPoint(x: b.x + w * 0.14, y: b.y))
        p.lineWidth = w * 0.045; p.lineCapStyle = .round; white.setStroke(); p.stroke()
    }
    for t in targets {
        let r = pill(cx: t.x, cy: t.y, w: t.w, h: 0.12)
        t.color.setFill(); NSBezierPath(roundedRect: r, xRadius: r.height * 0.4, yRadius: r.height * 0.4).fill()
    }
    white.setFill(); NSBezierPath(roundedRect: rootR, xRadius: rootR.height * 0.36, yRadius: rootR.height * 0.36).fill()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

var entries: [String] = []
entries.append(#"{"filename": "ios_1024.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"}"#)
try draw(1024, rounded: false).write(to: set.appendingPathComponent("ios_1024.png"))
for pt in [16, 32, 128, 256, 512] {
    for sc in [1, 2] {
        let n = "mac_\(pt)@\(sc)x.png"
        entries.append(#"{"filename": "\#(n)", "idiom": "mac", "scale": "\#(sc)x", "size": "\#(pt)x\#(pt)"}"#)
        try draw(pt * sc, rounded: true).write(to: set.appendingPathComponent(n))
    }
}
let json = "{\n  \"images\": [\n" + entries.map { "    " + $0 }.joined(separator: ",\n") + "\n  ],\n  \"info\": {\"author\": \"xcode\", \"version\": 1}\n}\n"
try json.write(to: set.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
try #"{"info": {"author": "xcode", "version": 1}}"#.write(to: root.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
if CommandLine.arguments.count > 2 {
    try draw(1024, rounded: true).write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
}
