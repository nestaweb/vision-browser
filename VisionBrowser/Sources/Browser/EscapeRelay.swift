import WebKit

/// `Échap` ouvre la vue d'ensemble (F2), **seulement si la page ne s'en est pas servie**.
///
/// La décision est prise côté natif : une touche que la page n'utilise pas (pas de `preventDefault`) est rendue
/// par WebKit à la fenêtre (`BrowserWindow`). Pour savoir si un champ était en cours de saisie ou un dialogue
/// ouvert, un script placé dans chaque cadre, dans un monde isolé (invisible pour la page), signale son état
/// au moment de l'appui.
///
/// Pourquoi pas tout en JavaScript (version précédente) : la touche remontait quand même côté natif, d'où le bip
/// d'erreur de macOS, la sortie du plein écran, et rien du tout sur un PDF (aucun script n'y tourne).
@MainActor
final class EscapeRelay: NSObject, WKScriptMessageHandler {
    static let shared = EscapeRelay()
    static let world = WKContentWorld.world(name: "VisionBrowser")
    private static let name = "visionEscape"

    /// Dernier état signalé par une page : quand, par quelle vue, et si un champ ou un dialogue l'occupait.
    private var lastReport: (date: Date, webView: WKWebView?, busy: Bool)?

    /// L'état est relevé **avant** la page (phase de capture) : une page qui ferme sa liste et retire le focus
    /// pendant son propre traitement d'`Échap` ne doit pas ouvrir la vue d'ensemble.
    /// Chaque cadre a son propre script : seul le cadre qui a le focus reçoit la touche.
    static let source = """
    (() => {
      const occupied = () => {
        const a = document.activeElement;
        if (a && (a.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(a.tagName))) return true;
        if (a && a !== document.body && a.closest('[role="dialog"],[role="menu"],[role="listbox"],[role="combobox"]')) return true;
        if (document.fullscreenElement || document.webkitFullscreenElement) return true;
        try { if (document.querySelector('dialog[open], [aria-modal="true"], :popover-open')) return true; } catch (_) {}
        return false;
      };
      window.addEventListener('keydown', e => {
        if (e.key === 'Escape') window.webkit.messageHandlers.\(name).postMessage(occupied());
      }, true);
    })();
    """

    static func install(on config: WKWebViewConfiguration) {
        let controller = config.userContentController
        controller.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: world))
        controller.add(shared, contentWorld: world, name: name)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        lastReport = (Date(), message.webView, (message.body as? Bool) ?? false)
    }

    /// Vrai si la page se servait d'`Échap` (champ actif, dialogue, menu, plein écran d'un élément).
    /// Sans signalement récent (PDF, image : aucun script), rien n'occupe la page.
    func pageIsBusy(_ view: WKWebView) async -> Bool {
        // Le signalement part pendant que la page traite la touche ; on lui laisse un instant s'il n'est pas arrivé.
        if !hasRecentReport(for: view) { try? await Task.sleep(for: .milliseconds(40)) }
        guard hasRecentReport(for: view), let report = lastReport else { return false }
        lastReport = nil
        return report.busy
    }

    private func hasRecentReport(for view: WKWebView) -> Bool {
        guard let report = lastReport else { return false }
        return report.webView === view && Date().timeIntervalSince(report.date) < 1
    }
}

/// La fenêtre de navigation. Elle reçoit `Échap` quand rien d'autre ne l'a utilisé (page, champ, vue d'ensemble).
///
/// Par défaut `NSWindow` en fait « Annuler » : bip d'erreur, ou sortie du plein écran. Ici, la touche est toujours
/// confiée au navigateur, qui décide (vue d'ensemble, fermer une surcouche, ou rien).
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
