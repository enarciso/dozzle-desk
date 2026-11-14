// Draws the 1280×640 GitHub social preview (Settings → General → Social preview) from the
// README card screenshot and the app icon, in the icon's navy and pulse blue.
//   swift scripts/make-social.swift docs/card.png Assets/icon-1024.png docs/social-preview.png
import AppKit

let args = CommandLine.arguments
guard args.count == 4, let card = NSImage(contentsOfFile: args[1]), let icon = NSImage(contentsOfFile: args[2]) else {
    print("usage: make-social.swift CARD.png ICON.png OUT.png"); exit(1)
}
func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}
let size = NSSize(width: 1280, height: 640)
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1280, pixelsHigh: 640, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// The icon's body gradient, darkened so the card and text stand out.
NSGradient(colors: [rgb(0x18335C), rgb(0x0E1A30), rgb(0x070C17)])!
    .draw(in: NSRect(origin: .zero, size: size), angle: -60)
// Soft light from the top left, like the icon's glow.
NSGradient(colors: [rgb(0x9CCBFF, 0.16), rgb(0x9CCBFF, 0)])!
    .draw(fromCenter: NSPoint(x: 260, y: 640), radius: 0, toCenter: NSPoint(x: 260, y: 640), radius: 620, options: [])

// The card, right side, as large as fits.
let cardH: CGFloat = 580
let cardW = card.size.width / card.size.height * cardH
let cardRect = NSRect(x: size.width - cardW - 56, y: (size.height - cardH) / 2, width: cardW, height: cardH)
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.6)
shadow.shadowBlurRadius = 40
shadow.shadowOffset = NSSize(width: 0, height: -12)
NSGraphicsContext.saveGraphicsState()
shadow.set()
card.draw(in: cardRect)
NSGraphicsContext.restoreGraphicsState()

// Icon, name and pitch, left side.
let left: CGFloat = 72
icon.draw(in: NSRect(x: left - 14, y: 432, width: 140, height: 140))
/// `top` is the distance from the bottom of the image to the top of the text block.
func text(_ s: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, top: CGFloat, width: CGFloat = 600) {
    let style = NSMutableParagraphStyle()
    style.lineSpacing = 6
    NSAttributedString(string: s, attributes: [
        .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .paragraphStyle: style,
    ]).draw(in: NSRect(x: left, y: top - 200, width: width, height: 200))
}
text("DozzleDesk", size: 72, weight: .bold, color: .white, top: 420)
text("Live container health from Dozzle, on the macOS desktop and menu bar.",
     size: 30, weight: .regular, color: NSColor.white.withAlphaComponent(0.78), top: 322, width: 600)
text("hosts · containers · health · restarts · Swarm · Kubernetes",
     size: 19, weight: .medium, color: rgb(0x6FC8FF), top: 214, width: 620)

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[3]))
print("wrote \(args[3])")
