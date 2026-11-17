// Fond de la fenêtre d'installation (.dmg) de Vision Browser : le bonhomme va lui-même dans Applications.
// À gauche l'app, à droite le dossier Applications ; entre les deux, sa trace de pas : les onglets de la rangée
// posés comme des empreintes, en arc, de plus en plus marqués vers Applications. Papier et encre, aplats.
// Usage : swift scripts/make-dmg-background.swift <dossier de sortie>  → background.png et background@2x.png
import AppKit

let size = CGSize(width: 640, height: 400)
/// Centres des deux icônes dans la fenêtre (repris par scripts/make-dmg.sh pour placer les icônes).
let appCenter = CGPoint(x: 170, y: 214), applicationsCenter = CGPoint(x: 470, y: 214)
let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}
let ink: UInt32 = 0x1C1C1A, paper: UInt32 = 0xF2F0EB

func render(scale: CGFloat) -> Data {
    let pixels = NSSize(width: size.width * scale, height: size.height * scale)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(pixels.width), pixelsHigh: Int(pixels.height), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = context
    // Repère retourné : y vers le bas, comme la fenêtre du Finder.
    context.cgContext.translateBy(x: 0, y: size.height)
    context.cgContext.scaleBy(x: 1, y: -1)
    let flipped = NSGraphicsContext(cgContext: context.cgContext, flipped: true)
    NSGraphicsContext.current = flipped

    color(paper).setFill()
    NSRect(origin: .zero, size: size).fill()

    // Titre et consigne.
    let title = NSAttributedString(string: "Vision Browser", attributes: [
        .font: NSFont.systemFont(ofSize: 17, weight: .semibold), .foregroundColor: color(ink), .kern: -0.2])
    let hint = NSAttributedString(string: "Glisse-le dans Applications", attributes: [
        .font: NSFont.systemFont(ofSize: 12), .foregroundColor: color(ink, 0.55)])
    title.draw(at: NSPoint(x: (size.width - title.size().width) / 2, y: 52))
    hint.draw(at: NSPoint(x: (size.width - hint.size().width) / 2, y: 78))

    // La trace de pas : six empreintes le long d'un arc doux, alternées gauche / droite, inclinées dans le sens de la
    // marche, de plus en plus marquées vers Applications.
    let steps = 6
    let from = appCenter.x + 82, to = applicationsCenter.x - 82
    for i in 0..<steps {
        let t = CGFloat(i) / CGFloat(steps - 1)
        let x = from + (to - from) * t
        let y = appCenter.y - 16 * sin(.pi * t) + (i % 2 == 0 ? -4 : 4)
        let slope = atan(-16 * .pi * cos(.pi * t) / (to - from))   // tangente de l'arc
        let transform = NSAffineTransform()
        transform.translateX(by: x, yBy: y)
        transform.rotate(byRadians: slope)
        let foot = NSBezierPath(roundedRect: NSRect(x: -9, y: -5.5, width: 18, height: 11), xRadius: 3, yRadius: 3)
        foot.transform(using: transform as AffineTransform)
        color(ink, 0.12 + 0.38 * t).setFill()
        foot.fill()
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

try render(scale: 1).write(to: out.appendingPathComponent("background.png"))
try render(scale: 2).write(to: out.appendingPathComponent("background@2x.png"))
print("fond écrit :", out.path)
