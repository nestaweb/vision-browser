import WebKit

/// Un espace = un coffre de données WebKit indépendant (cookies, stockage local, cache) + un nom + une couleur.
/// Les identifiants sont fixes : les sessions persistent d'un lancement à l'autre.
@MainActor
final class Space {
    let id: UUID
    var name: String
    var colorIndex: Int
    let store: WKWebsiteDataStore

    init(record: SpaceRecord) {
        id = record.id
        name = record.name
        colorIndex = record.colorIndex
        store = WKWebsiteDataStore(forIdentifier: record.id)
    }

    var color: NSColor { Self.palette[colorIndex % Self.palette.count] }

    /// Palette des espaces (même nombre d'entrées que `SpacesConfig.paletteCount`).
    static let palette: [NSColor] = [.systemTeal, .systemOrange, .systemPink, .systemPurple,
                                     .systemBlue, .systemGreen, .systemYellow, .systemRed]

    /// Pastille de couleur pour les menus.
    var swatch: NSImage {
        let image = NSImage(size: NSSize(width: 10, height: 10), flipped: false) { [color] rect in
            color.setFill()
            NSBezierPath(ovalIn: rect).fill()
            return true
        }
        return image
    }
}
