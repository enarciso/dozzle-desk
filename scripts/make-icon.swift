// Draws the DozzleDesk icon with CoreGraphics and writes a macOS .iconset (every size drawn
// from vectors, not scaled down) plus a 1024 px preview PNG.
//
//   scripts/make-icon.sh   (runs this, then iconutil, leaving Assets/AppIcon.icns)
//
// Design: a stack of three glass server slabs (the menu bar's rack) with status lights,
// crossed by a live pulse line, on the dashboard's dark navy. 1024-pt canvas, Apple's icon grid.
import AppKit
import CoreGraphics

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Assets"
let space = CGColorSpace(name: CGColorSpace.sRGB)!

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [
        CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255, CGFloat(hex & 0xFF) / 255, a])!
}

let green = rgb(0x4CD980)
let amber = rgb(0xFFB840)
let pulse = rgb(0x6FC8FF)

func linear(_ cg: CGContext, _ colors: [CGColor], from: CGPoint, to: CGPoint) {
    let g = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: nil)!
    cg.drawLinearGradient(g, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

/// `small` (16–32 px): bolder shapes and no glows, which would otherwise smear into mush.
func draw(_ cg: CGContext, small: Bool) {
    // Body: Apple's macOS grid puts the 824-pt rounded square inside the 1024 canvas.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

    cg.saveGState()
    if !small { cg.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: rgb(0x000000, 0.45)) }
    cg.addPath(bodyPath)
    cg.setFillColor(rgb(0x0D1526))
    cg.fillPath()
    cg.restoreGState()

    cg.saveGState()
    cg.addPath(bodyPath)
    cg.clip()
    linear(cg, [rgb(0x24508F), rgb(0x142744), rgb(0x0A1120)],
           from: CGPoint(x: 512, y: 924), to: CGPoint(x: 512, y: 100))
    // Soft light from the top, like the card's blur picking up the wallpaper.
    let glow = CGGradient(colorsSpace: space, colors: [rgb(0x9CCBFF, 0.30), rgb(0x9CCBFF, 0)] as CFArray, locations: nil)!
    cg.drawRadialGradient(glow, startCenter: CGPoint(x: 400, y: 960), startRadius: 0,
                          endCenter: CGPoint(x: 400, y: 960), endRadius: 620, options: [])
    cg.restoreGState()

    // Hairline rim.
    cg.addPath(CGPath(roundedRect: body.insetBy(dx: 2, dy: 2), cornerWidth: 183, cornerHeight: 183, transform: nil))
    cg.setStrokeColor(rgb(0xFFFFFF, 0.14))
    cg.setLineWidth(4)
    cg.strokePath()

    // Three glass slabs with status lights: healthy, healthy, needs attention.
    let lights = [green, green, amber]
    for (i, light) in lights.enumerated() {
        let slab = CGRect(x: 222, y: 618 - CGFloat(i) * 170, width: 580, height: 132)
        let path = CGPath(roundedRect: slab, cornerWidth: 36, cornerHeight: 36, transform: nil)
        cg.saveGState()
        cg.addPath(path)
        cg.clip()
        linear(cg, small ? [rgb(0xFFFFFF, 0.24), rgb(0xFFFFFF, 0.16)] : [rgb(0xFFFFFF, 0.20), rgb(0xFFFFFF, 0.07)],
               from: CGPoint(x: 0, y: slab.maxY), to: CGPoint(x: 0, y: slab.minY))
        cg.restoreGState()
        if !small {
            cg.addPath(path)
            cg.setStrokeColor(rgb(0xFFFFFF, 0.26))
            cg.setLineWidth(4)
            cg.strokePath()
        }

        let c = CGPoint(x: slab.minX + 76, y: slab.midY)
        let r: CGFloat = small ? 34 : 24
        cg.saveGState()
        if !small { cg.setShadow(offset: .zero, blur: 30, color: light) }
        cg.setFillColor(light)
        cg.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
        cg.restoreGState()
        if !small {
            cg.setFillColor(rgb(0xFFFFFF, 0.55))
            cg.fillEllipse(in: CGRect(x: c.x - 9, y: c.y + 3, width: 14, height: 12))   // glint
        }
    }

    // The pulse: flat, a sharp beat across the stack, flat again.
    let beat = CGMutablePath()
    beat.move(to: CGPoint(x: small ? 400 : 380, y: 520))
    beat.addLine(to: CGPoint(x: 470, y: 520))
    beat.addLine(to: CGPoint(x: 530, y: 742))
    beat.addLine(to: CGPoint(x: 606, y: 300))
    beat.addLine(to: CGPoint(x: 664, y: 584))
    beat.addLine(to: CGPoint(x: 700, y: 520))
    beat.addLine(to: CGPoint(x: 800, y: 520))

    cg.saveGState()
    cg.setLineCap(.round)
    cg.setLineJoin(.round)
    cg.addPath(beat)
    if !small { cg.setShadow(offset: .zero, blur: 46, color: pulse) }
    cg.setStrokeColor(pulse)
    cg.setLineWidth(small ? 64 : 30)
    cg.strokePath()
    cg.restoreGState()

    cg.saveGState()
    cg.setLineCap(.round)
    cg.setLineJoin(.round)
    cg.addPath(beat)
    cg.setStrokeColor(rgb(0xE6F5FF))
    cg.setLineWidth(small ? 26 : 11)
    cg.strokePath()
    cg.restoreGState()
}

func png(_ px: Int) -> Data {
    let cg = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                       bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    cg.interpolationQuality = .high
    cg.scaleBy(x: CGFloat(px) / 1024, y: CGFloat(px) / 1024)
    draw(cg, small: px <= 32)
    return NSBitmapImageRep(cgImage: cg.makeImage()!).representation(using: .png, properties: [:])!
}

let iconset = URL(fileURLWithPath: outDir).appendingPathComponent("AppIcon.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for pt in [16, 32, 128, 256, 512] {
    try png(pt).write(to: iconset.appendingPathComponent("icon_\(pt)x\(pt).png"))
    try png(pt * 2).write(to: iconset.appendingPathComponent("icon_\(pt)x\(pt)@2x.png"))
}
try png(1024).write(to: URL(fileURLWithPath: outDir).appendingPathComponent("icon-1024.png"))
print("wrote \(iconset.path) and \(outDir)/icon-1024.png")
