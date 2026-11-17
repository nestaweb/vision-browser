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

    /// Couleur sourde de l'espace (jetons de `Design.Palette`), au lieu des couleurs système saturées.
    var color: NSColor { Design.Palette.space(colorIndex) }

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
