import Foundation

/// Comment une page arrive à l'écran (D2, direction « Scène »).
///
/// Même rangement partout : les onglets sont rangés à l'horizontale, les espaces empilés à la verticale.
/// Changer d'onglet fait donc glisser la page sur le côté, changer d'espace la fait glisser vers le haut ou le bas.
/// Logique pure : la fenêtre ne fait qu'animer le résultat.
enum PageTransition: Equatable, Sendable {
    /// Pas d'animation (lancement, même page, rien d'affiché avant).
    case none
    /// Autre onglet du même espace. `direction` : +1 = un onglet plus à droite, −1 = plus à gauche.
    case tab(direction: Int)
    /// Autre espace. `direction` : +1 = l'espace suivant (en dessous), −1 = le précédent (au-dessus).
    case space(direction: Int)

    /// - Parameters:
    ///   - fromSpace / toSpace: rang des espaces (avant / après) ; `fromSpace` nil si rien n'était affiché.
    ///   - fromTab / toTab: rang des onglets dans l'espace ; `fromTab` nil si l'ancien onglet n'y est plus (fermé).
    ///   - spaceStep: sens demandé explicitement (⇧← / ⇧→, qui bouclent : du dernier espace au premier, on descend).
    static func between(fromSpace: Int?, toSpace: Int, fromTab: Int?, toTab: Int, spaceStep: Int? = nil) -> PageTransition {
        guard let fromSpace else { return .none }
        if fromSpace != toSpace {
            if let spaceStep, spaceStep != 0 { return .space(direction: spaceStep > 0 ? 1 : -1) }
            return .space(direction: toSpace > fromSpace ? 1 : -1)
        }
        guard let fromTab, fromTab != toTab else { return .none }
        return .tab(direction: toTab > fromTab ? 1 : -1)
    }

    /// Décalage de départ de la nouvelle page, en points, dans le repère de l'écran (y vers le bas).
    /// Les espaces font un pas plus grand : on change de « plan », pas seulement de page.
    var entryOffset: (x: CGFloat, y: CGFloat) {
        switch self {
        case .none: (0, 0)
        case .tab(let direction): (CGFloat(direction) * 28, 0)
        case .space(let direction): (0, CGFloat(direction) * 64)
        }
    }

    /// L'ancienne page s'efface d'un demi-pas dans le sens opposé (changement d'espace seulement).
    var exitOffset: (x: CGFloat, y: CGFloat)? {
        if case .space(let direction) = self { return (0, CGFloat(-direction) * 32) }
        return nil
    }
}
