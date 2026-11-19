import WebKit

/// Monde JavaScript isolé de l'app : ses scripts (copie, remplissage Bitwarden) sont invisibles pour la page,
/// qui ne peut ni les lire ni les imiter.
@MainActor
enum ScriptWorld {
    static let app = WKContentWorld.world(name: "VisionBrowser")
}

/// La fenêtre de navigation. Elle reçoit `Échap` quand rien d'autre ne l'a utilisé (page, champ, vue d'ensemble).
///
/// Par défaut `NSWindow` en fait « Annuler » (bip d'erreur) et, en plein écran, en sort. Ici, la touche est toujours
/// confiée au navigateur, qui referme la surcouche ouverte (barre Cmd+T, Scène), ou ne fait rien.
final class BrowserWindow: NSWindow {
    var onEscape: (() -> Void)?

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }


    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if event.keyCode == 53, flags.isEmpty {
            if !event.isARepeat { onEscape?() }
            return
        }
        super.keyDown(with: event)
    }
}

/// Conteneur des pages : la vue juste au-dessus de la page dans la chaîne des répondeurs.
///
/// Une touche Échap que la page n'utilise pas revient de WebKit sous forme de commande « Annuler », qui remonte
/// la chaîne des vues. En plein écran, le cadre de la fenêtre (vue interne d'AppKit, avant la fenêtre dans cette
/// chaîne) la traite en **quittant le plein écran** : la fenêtre ne la voyait jamais. On l'arrête donc ici, au premier
/// maillon après la page (constaté par la pile d'appels de la sortie du plein écran).
final class PageContainerView: NSView {
    var onEscape: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}
