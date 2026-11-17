// Dessine l'icône de Vision Browser (le bonhomme « Scène », design/logo.svg) à toutes les tailles macOS
// et écrit l'ensemble AppIcon.appiconset. Usage : swift scripts/make-icon.swift <dossier .appiconset>
// Même géométrie que le SVG (toile 1024, y vers le bas), redessinée à chaque taille : tracé net partout.
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func render(pixels: Int) -> Data {
    let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let k = CGFloat(pixels) / 1024
    ctx.translateBy(x: 0, y: CGFloat(pixels))
    ctx.scaleBy(x: k, y: -k)   // repère du SVG : y vers le bas
    func box(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat, _ c: CGColor) {
        ctx.addPath(CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerWidth: r, cornerHeight: r, transform: nil))
        ctx.setFillColor(c)
        ctx.fillPath()
    }
    let paper: UInt32 = 0xF2F0EB
    box(100, 100, 824, 824, 186, color(0x252523))          // corps
    box(262, 236, 500, 312, 22, color(paper))               // la page : la tête
    box(418, 338, 22, 84, 11, color(0x1C1C1A))              // yeux
    box(584, 338, 22, 84, 11, color(0x1C1C1A))
    box(262, 626, 148, 92, 14, color(paper, 0.32))          // épaules : onglets
    box(438, 604, 148, 92, 14, color(paper))                // onglet choisi, relevé
    box(614, 626, 148, 92, 14, color(paper, 0.32))
    let image = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    return image.representation(using: .png, properties: [:])!
}

var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try render(pixels: points * scale).write(to: out.appendingPathComponent(name))
        images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys]).write(to: out.appendingPathComponent("Contents.json"))
print("icône écrite :", out.path)
