import WebKit

/// `Échap` ouvre la vue d'ensemble (F2), **seulement si la page ne s'en est pas servie**.
///
/// Un script, dans un monde isolé (invisible pour la page), écoute `Échap` après les gestionnaires de la page.
/// Si personne ne l'a traité (pas de `preventDefault`), qu'aucun champ n'est en cours de saisie, et qu'il n'y a
/// ni plein écran ni dialogue ouvert, il prévient le navigateur. Intercepter `Échap` côté natif casserait
/// la fermeture des fenêtres modales des sites.
@MainActor
final class EscapeRelay: NSObject, WKScriptMessageHandler {
    static let shared = EscapeRelay()
    static let world = WKContentWorld.world(name: "VisionBrowser")
    private static let name = "visionEscape"

    /// Reçoit la vue web où `Échap` n'a pas été utilisé.
    var onUnhandledEscape: ((WKWebView?) -> Void)?

    /// L'état est relevé **avant** la page (phase de capture) : une page qui ferme sa liste et retire le focus
    /// pendant son propre traitement d'`Échap` ne doit pas ouvrir la vue d'ensemble.
    static let source = """
    (() => {
      let busy = false;
      const occupied = () => {
        const a = document.activeElement;
        if (a && (a.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(a.tagName))) return true;
        if (a && a !== document.body && a.closest('[role="dialog"],[role="menu"],[role="listbox"],[role="combobox"]')) return true;
        if (document.fullscreenElement || document.webkitFullscreenElement) return true;
        try { if (document.querySelector('dialog[open], [aria-modal="true"], :popover-open')) return true; } catch (_) {}
        return false;
      };
      window.addEventListener('keydown', e => { if (e.key === 'Escape') busy = occupied(); }, true);
      window.addEventListener('keydown', e => {
        if (e.key !== 'Escape' || busy || e.defaultPrevented || e.repeat || e.metaKey || e.ctrlKey || e.altKey || e.shiftKey) return;
        window.webkit.messageHandlers.\(name).postMessage(null);
      });
    })();
    """

    static func install(on config: WKWebViewConfiguration) {
        let controller = config.userContentController
        controller.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: world))
        controller.add(shared, contentWorld: world, name: name)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        onUnhandledEscape?(message.webView)
    }
}
