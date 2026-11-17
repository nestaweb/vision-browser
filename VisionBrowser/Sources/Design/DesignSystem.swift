import AppKit
import QuartzCore

/// Jetons de la direction « Scène » (maquette : `maquette/scene.html`).
///
/// Une seule source pour les couleurs, le texte et le mouvement : chaque surface les lit ici au lieu de choisir
/// ses propres valeurs (avant : 10 rayons, 7 tailles de police, 3 durées, des couleurs système saturées).
/// Règles : aplats, une seule ombre par surface, aucun dégradé ni lueur, pas de rebond.
enum Design {

    // MARK: Couleurs

    enum Palette {
        /// Encre : texte et surfaces sombres (#1C1C1A).
        static var ink: NSColor { srgb(0x1C1C1A) }
        /// Papier : texte sur fond sombre, surfaces claires (#F2F0EB).
        static var paper: NSColor { srgb(0xF2F0EB) }
        /// Feuille : fond de la barre Cmd+T (#FBFAF7).
        static var sheet: NSColor { srgb(0xFBFAF7) }
        /// Salle : fond de la vue d'ensemble « Scène », derrière la page qui recule (#252523).
        static var house: NSColor { srgb(0x252523) }
        /// Voile posé sur la page quand la barre Cmd+T est ouverte (noir à 26 %).
        static var veil: NSColor { srgb(0x0C0C0B).withAlphaComponent(0.26) }
        /// Filets de séparation sur fond clair.
        static var rule: NSColor { ink.withAlphaComponent(0.10) }

        /// Niveaux de texte : principal, secondaire, discret.
        static func ink(_ level: Level) -> NSColor { ink.withAlphaComponent(level.alpha) }
        static func paper(_ level: Level) -> NSColor { paper.withAlphaComponent(level.alpha) }

        enum Level {
            case primary, secondary, tertiary
            var alpha: CGFloat {
                switch self {
                case .primary: 1
                case .secondary: 0.55
                case .tertiary: 0.30
                }
            }
        }

        /// Couleurs d'espace : pigments sourds, lisibles sur la salle comme sur le papier.
        /// Elles ne servent qu'à de petites marques (trait du rail, étiquette), jamais en aplat ni en lueur.
        /// Même ordre que l'ancienne palette système, pour que chaque espace garde sa teinte.
        static let spacePigments: [UInt32] = [
            0x3F8A8C, // sarcelle   (ancien teal)
            0xB5844A, // ocre       (ancien orange)
            0xB5577A, // framboise  (ancien rose)
            0x7A5EA8, // violet     (ancien violet)
            0x4A6FA5, // ardoise    (ancien bleu)
            0x5F8A4E, // sauge      (ancien vert)
            0xA99052, // moutarde   (ancien jaune)
            0xA8513B, // brique     (ancien rouge)
        ]
        static func space(_ index: Int) -> NSColor { srgb(spacePigments[index % spacePigments.count]) }

        static func srgb(_ hex: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                    blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
    }

    // MARK: Texte

    /// SF Pro seule, trois tailles, chiffres de largeur égale (compteurs, numéros).
    enum Typography {
        static let smallSize: CGFloat = 12
        static let bodySize: CGFloat = 14
        static let fieldSize: CGFloat = 20

        static var small: NSFont { .monospacedDigitSystemFont(ofSize: smallSize, weight: .regular) }
        static var body: NSFont { .monospacedDigitSystemFont(ofSize: bodySize, weight: .regular) }
        static var bodyStrong: NSFont { .monospacedDigitSystemFont(ofSize: bodySize, weight: .semibold) }
        static var field: NSFont { .systemFont(ofSize: fieldSize, weight: .regular) }

        /// Étiquette en capitales espacées (type de résultat, nom d'espace dans une marge).
        static func label(_ text: String, color: NSColor) -> NSAttributedString {
            let font = NSFont.systemFont(ofSize: 10.5, weight: .semibold)
            return NSAttributedString(string: text.uppercased(with: Locale(identifier: "fr_FR")),
                                      attributes: [.font: font, .foregroundColor: color, .kern: font.pointSize * 0.1])
        }
    }

    // MARK: Formes

    enum Shape {
        /// Barre Cmd+T.
        static let barRadius: CGFloat = 12
        /// Ligne choisie dans une liste (rayon intérieur = rayon de la barre − sa marge).
        static let rowRadius: CGFloat = 7
        /// Page qui recule dans la Scène.
        static let stageRadius: CGFloat = 10
        /// Vignettes de la rangée.
        static let thumbRadius: CGFloat = 5
    }

    // MARK: Mouvement

    /// Tout part vite et se pose sans dépasser. Trois durées seulement.
    enum Motion {
        enum Speed: Sendable {
            /// 140 ms : sélection, traits, petits éléments.
            case fast
            /// 220 ms : barre, étiquettes, voile.
            case medium
            /// 340 ms : pages, Scène.
            case slow

            var base: TimeInterval {
                switch self {
                case .fast: 0.14
                case .medium: 0.22
                case .slow: 0.34
                }
            }
        }

        /// Courbe commune (mêmes points de contrôle que la maquette : cubic-bezier(.2, .8, .2, 1)).
        static var curve: CAMediaTimingFunction { CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1) }

        /// Option de lancement pour vérifier les animations à l'œil : `-VBSlowMotion 4`.
        static var slowFactor: Double {
            let value = UserDefaults.standard.double(forKey: "VBSlowMotion")
            return value >= 1 ? value : 1
        }

        /// Réglage macOS « Réduire les animations » : les déplacements sont remplacés par de simples fondus.
        /// Option de lancement pour vérifier ce mode sans toucher aux réglages du Mac : `-VBReduceMotion YES`.
        @MainActor static var reduceMotion: Bool {
            UserDefaults.standard.bool(forKey: "VBReduceMotion") || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        }

        /// Durée effective : allongée par le ralenti, et inchangée avec « Réduire les animations »
        /// (seuls les déplacements disparaissent, voir `allowsMovement`).
        static func duration(_ speed: Speed, slowFactor: Double = slowFactor) -> TimeInterval {
            speed.base * max(slowFactor, 1)
        }

        /// Faut-il déplacer, agrandir ou réduire (sinon : fondu seul) ?
        /// - Parameter reduceMotion: pour les tests ; par défaut, le réglage du Mac.
        @MainActor static func allowsMovement(reduceMotion: Bool? = nil) -> Bool { !(reduceMotion ?? Self.reduceMotion) }

        /// Anime des changements AppKit (`animator()`, contraintes) avec la durée et la courbe communes.
        @MainActor
        static func animate(_ speed: Speed, _ changes: @escaping @MainActor () -> Void,
                            completion: (@MainActor @Sendable () -> Void)? = nil) {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = duration(speed)
                context.timingFunction = curve
                context.allowsImplicitAnimation = true
                MainActor.assumeIsolated { changes() }
            }, completionHandler: completion.map { done in { MainActor.assumeIsolated { done() } } })
        }
    }
}
