import CoreGraphics

/// Géométrie de la vue d'ensemble « Scène » (D3) : la page recule au centre, la rangée des onglets dessous,
/// le rail des espaces à gauche. Repère retourné (origine en haut à gauche), comme les vues de la Scène.
/// Logique pure, testée ; la vue ne fait que placer ses éléments aux cadres calculés ici.
struct SceneLayout: Equatable {
    /// Hauteur des vignettes de la rangée pour les trois tailles (petites, moyennes, grandes).
    static let thumbHeights: [CGFloat] = [92, 120, 150]
    static let railWidth: CGFloat = 200
    static let margin: CGFloat = 40
    /// Espace entre le bas de la page et la rangée : la légende (titre, adresse) s'y loge.
    static let captionBand: CGFloat = 64
    /// Nom sous chaque vignette.
    static let nameHeight: CGFloat = 26

    let bounds: CGSize
    let size: Int

    init(bounds: CGSize, size: Int) {
        self.bounds = bounds
        self.size = min(max(size, 0), Self.thumbHeights.count - 1)
    }

    /// Proportions de la page (celles de la fenêtre), bornées pour rester lisibles.
    var aspect: CGFloat {
        guard bounds.height > 0 else { return 1.6 }
        return min(max(bounds.width / bounds.height, 1.2), 2.4)
    }

    var thumbSize: CGSize {
        let height = Self.thumbHeights[size]
        return CGSize(width: (height * aspect).rounded(), height: height)
    }

    /// Haut de la rangée (vignettes et noms).
    var rowTop: CGFloat { bounds.height - Self.margin - thumbSize.height - Self.nameHeight }

    /// Cadre de la page qui recule : le plus grand possible entre le rail et la marge, au-dessus de la légende,
    /// aux proportions de la fenêtre.
    var stage: CGRect {
        let areaLeft = Self.railWidth, areaRight = bounds.width - Self.margin
        let top = Self.margin, bottom = rowTop - Self.captionBand
        var height = max(bottom - top, 1)
        var width = height * aspect
        if width > areaRight - areaLeft {
            width = max(areaRight - areaLeft, 1)
            height = width / aspect
        }
        let x = areaLeft + (areaRight - areaLeft - width) / 2
        return CGRect(x: x.rounded(), y: top, width: width.rounded(), height: height.rounded())
    }

    /// Légende sous la page : alignée sur elle.
    var caption: CGRect {
        CGRect(x: stage.minX, y: stage.maxY + 18, width: stage.width, height: 20)
    }

    /// Rangée : du rail au bord droit (elle défile si les onglets dépassent).
    var row: CGRect {
        CGRect(x: Self.railWidth, y: rowTop - 12, width: bounds.width - Self.railWidth, height: thumbSize.height + Self.nameHeight + 12)
    }

    /// Rail des espaces.
    var rail: CGRect { CGRect(x: 0, y: 0, width: Self.railWidth, height: bounds.height) }

    /// Passer d'un élément à son voisin, sans sortir de la liste.
    static func step(_ index: Int, by delta: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return min(max(index + delta, 0), count - 1)
    }
}
