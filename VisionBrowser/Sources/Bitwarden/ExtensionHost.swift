import WebKit

/// Héberge Bitwarden (build Firefox, Manifest V2) dans WebKit.
/// Reprend tout ce que la phase 0 a validé :
/// - user agent Firefox pour les pages de l'extension (Bitwarden détecte le navigateur par là) ;
/// - identifiant stable (le stockage de l'extension, donc la session, est rangé sous cet identifiant) ;
/// - couche de compatibilité WebKit (permissions inconnues de WebKit) ;
/// - l'extension doit être chargée avant l'ouverture des onglets.
@MainActor
final class ExtensionHost: NSObject, WKWebExtensionControllerDelegate {
    let controller: WKWebExtensionController
    private(set) var context: WKWebExtensionContext?
    weak var window: BrowserWindowController?
    private var extensionWindows: [NSWindow] = []

    /// Identifiant fixe de Bitwarden dans Vision Browser : ne jamais le changer, il porte les données de l'extension.
    static let bitwardenIdentifier = "b17a2d3e-0000-4000-8000-b17a2d3e0001"
    static var bitwardenDirectory: URL { AppPaths.extensions.appendingPathComponent("bitwarden", isDirectory: true) }

    override init() {
        let configuration = WKWebExtensionController.Configuration.default()
        let pages = configuration.webViewConfiguration ?? WKWebViewConfiguration()
        pages.applicationNameForUserAgent = "Gecko/20100101 Firefox/140.0"
        ExtensionCompat.install(on: pages)
        ExtensionDebugConsole.installIfEnabled(on: pages)
        configuration.webViewConfiguration = pages
        controller = WKWebExtensionController(configuration: configuration)
        super.init()
        controller.delegate = self
    }

    /// Charge Bitwarden et renvoie un rapport lisible (journal système).
    func loadBitwarden() async -> [String] {
        let dir = Self.bitwardenDirectory
        guard FileManager.default.fileExists(atPath: dir.appendingPathComponent("manifest.json").path) else {
            return ["absent de \(dir.path) : lancer scripts/install-bitwarden.sh"]
        }
        do {
            let ext = try await WKWebExtension(resourceBaseURL: dir)
            let context = WKWebExtensionContext(for: ext)
            context.uniqueIdentifier = Self.bitwardenIdentifier
            // « webkit-extension: » est imposé par WebKit (tout autre protocole bloque le chargement) ;
            // Bitwarden l'accepte grâce à scripts/patch-bitwarden.sh.
            context.baseURL = URL(string: "webkit-extension://\(Self.bitwardenIdentifier)/")!
            context.isInspectable = true
            // Bitwarden est installé délibérément par l'utilisateur : on accorde ce qu'il demande.
            ext.requestedPermissions.forEach { context.setPermissionStatus(.grantedExplicitly, for: $0) }
            ext.allRequestedMatchPatterns.forEach { context.setPermissionStatus(.grantedExplicitly, for: $0) }
            try controller.load(context)
            self.context = context
            // Non bloquant : l'arrière-plan démarre en tâche de fond.
            Task {
                do { try await context.loadBackgroundContent() }
                catch { NSLog("Vision Browser · Bitwarden : arrière-plan en échec : \(error.localizedDescription)") }
            }
            return ["\(ext.displayName ?? "?") \(ext.displayVersion ?? "") chargé"] + ext.errors.map { "avertissement : \($0.localizedDescription)" }
        } catch {
            return ["échec du chargement : \(error.localizedDescription)"]
        }
    }

    func performAction(for tab: BrowserTab?) {
        context?.performAction(for: tab)
    }

    // MARK: WKWebExtensionControllerDelegate

    func webExtensionController(_ controller: WKWebExtensionController, openWindowsFor extensionContext: WKWebExtensionContext) -> [any WKWebExtensionWindow] {
        window.map { [$0] } ?? []
    }

    func webExtensionController(_ controller: WKWebExtensionController, focusedWindowFor extensionContext: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        window
    }

    /// Popup de l'extension, ancré au coin supérieur droit (il n'y a pas de barre d'outils).
    func webExtensionController(_ controller: WKWebExtensionController, presentActionPopup action: WKWebExtension.Action,
                                for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        guard let popover = action.popupPopover, let anchor = window?.popupAnchor else { return completionHandler(nil) }
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        // Ce qui est copié pendant que le popup est ouvert vient de Bitwarden : traité comme un secret.
        ClipboardMonitor.shared.bitwardenPopupDidOpen()
        NotificationCenter.default.addObserver(self, selector: #selector(popupDidClose(_:)), name: NSPopover.didCloseNotification, object: popover)
        completionHandler(nil)
    }

    @objc private func popupDidClose(_ notification: Notification) {
        NotificationCenter.default.removeObserver(self, name: NSPopover.didCloseNotification, object: notification.object)
        ClipboardMonitor.shared.bitwardenPopupDidClose()
    }

    /// Pages internes de l'extension : fenêtre dédiée. Sites web : nouvel onglet.
    func webExtensionController(_ controller: WKWebExtensionController, openNewTabUsing configuration: WKWebExtension.TabConfiguration,
                                for context: WKWebExtensionContext, completionHandler: @escaping ((any WKWebExtensionTab)?, Error?) -> Void) {
        guard let url = configuration.url else { return completionHandler(nil, nil) }
        if url.scheme == context.baseURL.scheme {
            openExtensionPage(url, context: context)
            completionHandler(nil, nil)
        } else {
            completionHandler(window?.newTab(url: url, activate: configuration.shouldBeActive), nil)
        }
    }

    /// `windows.create` (ex. « détacher » le coffre de Bitwarden dans sa propre fenêtre).
    func webExtensionController(_ controller: WKWebExtensionController, openNewWindowUsing configuration: WKWebExtension.WindowConfiguration,
                                for context: WKWebExtensionContext, completionHandler: @escaping ((any WKWebExtensionWindow)?, Error?) -> Void) {
        configuration.tabURLs.forEach { url in
            if url.scheme == context.baseURL.scheme { openExtensionPage(url, context: context) }
            else { window?.newTab(url: url, activate: true) }
        }
        completionHandler(nil, nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, openOptionsPageFor extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping (Error?) -> Void) {
        if let url = extensionContext.optionsPageURL { openExtensionPage(url, context: extensionContext) }
        completionHandler(nil)
    }

    /// Bitwarden est installé délibérément : ses demandes de permissions supplémentaires sont accordées.
    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissions permissions: Set<WKWebExtension.Permission>,
                                in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping (Set<WKWebExtension.Permission>, Date?) -> Void) {
        completionHandler(permissions, nil)
    }

    /// Messages natifs (ex. déverrouillage par Touch ID via l'app Bitwarden de bureau) : pas encore pris en charge.
    func webExtensionController(_ controller: WKWebExtensionController, sendMessage message: Any, toApplicationWithIdentifier applicationIdentifier: String?,
                                for extensionContext: WKWebExtensionContext, replyHandler: @escaping (Any?, Error?) -> Void) {
        replyHandler(nil, nil)
    }

    private func openExtensionPage(_ url: URL, context: WKWebExtensionContext) {
        guard let configuration = context.webViewConfiguration else { return }
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 420, height: 640), configuration: configuration)
        let page = NSWindow(contentRect: webView.frame, styleMask: [.titled, .closable, .resizable, .miniaturizable],
                            backing: .buffered, defer: false)
        page.title = "Bitwarden"
        page.contentView = webView
        page.isReleasedWhenClosed = false
        page.center()
        page.makeKeyAndOrderFront(nil)
        extensionWindows.removeAll { !$0.isVisible }
        extensionWindows.append(page)
        webView.load(URLRequest(url: url))
    }
}
