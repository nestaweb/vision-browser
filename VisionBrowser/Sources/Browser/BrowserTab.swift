import WebKit
import UniformTypeIdentifiers

/// Un onglet : une page web, telle que l'utilisateur et l'extension (API `tabs.*`) la voient.
///
/// Un onglet peut **dormir** : il garde son adresse, son titre, sa capture et son état de navigation
/// (historique et défilement), mais relâche sa `WKWebView` (50 à 150 Mo). La vue est recréée au premier besoin.
@MainActor
final class BrowserTab: NSObject, WKWebExtensionTab, WKNavigationDelegate, WKUIDelegate {
    let id: UUID
    let space: Space
    /// Dernière activation (ordre récent : Ctrl+Tab, étagère, Cmd+T ; veille et archivage).
    var lastActivated: Date
    /// Épinglé dans son espace : jamais archivé, ↺ ramène à `homeURL`.
    var isPinned = false
    var homeURL: URL?
    weak var owner: BrowserWindowController?
    /// Onglet dont un lien a ouvert celui-ci (`target=_blank`) : « Précédent » sans historique y ramène.
    weak var opener: BrowserTab?
    private weak var host: ExtensionHost?

    /// La vue de la page si l'onglet est éveillé.
    private(set) var liveWebView: WKWebView?
    private var observations: [NSKeyValueObservation] = []
    /// Historique arrière/avant et position de défilement, gardés pendant la veille.
    private var savedInteractionState: Any?
    /// Adresse et titre connus même quand l'onglet dort.
    private(set) var url: URL?
    private(set) var title: String?
    /// URL précédente, pour savoir si le domaine a changé (indicateur de domaine).
    private(set) var previousURL: URL?

    var isAsleep: Bool { liveWebView == nil }
    var snapshot: NSImage? { SnapshotStore.shared.image(for: id) }

    /// - Parameter configuration: fournie par WebKit pour les fenêtres ouvertes par la page
    ///   (`target=_blank`, `window.open`) : la vue est alors créée tout de suite, sans chargement.
    /// - Parameter httpFallback: voir `load(_:httpFallback:)`, pour la première page de l'onglet.
    init(id: UUID = UUID(), space: Space, host: ExtensionHost, url: URL? = nil, title: String? = nil,
         lastActivated: Date = Date(), configuration: WKWebViewConfiguration? = nil, httpFallback: URL? = nil) {
        self.id = id
        self.space = space
        self.host = host
        self.url = url
        self.title = title
        self.lastActivated = lastActivated
        self.pendingHTTPFallback = httpFallback
        super.init()
        if let configuration { makeWebView(configuration: configuration) }
    }

    // MARK: Repli HTTPS → HTTP

    /// Adresse tapée sans schéma (`exemple.fr`) : elle part en HTTPS ; si le serveur n'y répond pas (port fermé,
    /// certificat refusé, ou rien au bout de `httpsPatience`), on la recharge en HTTP, comme Safari et Chrome.
    /// Jamais pour un lien, un favori ou une adresse tapée avec `https://` : là, l'échec reste un échec.
    private var pendingHTTPFallback: URL?
    private var httpsWatchdog: Task<Void, Never>?
    static let httpsPatience: Duration = .seconds(4)

    /// Charge une adresse ; `httpFallback` est sa version `http://` quand le schéma n'a pas été tapé.
    func load(_ url: URL, httpFallback: URL? = nil) {
        pendingHTTPFallback = httpFallback
        webView.load(URLRequest(url: url))
        armHTTPSWatchdog()
    }

    private func armHTTPSWatchdog() {
        httpsWatchdog?.cancel()
        guard pendingHTTPFallback != nil else { return }
        httpsWatchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.httpsPatience)
            guard !Task.isCancelled else { return }
            self?.fallBackToHTTP()
        }
    }

    /// Le serveur a répondu en HTTPS (ou une autre navigation a pris le relais) : plus de repli.
    private func settleHTTPS() {
        pendingHTTPFallback = nil
        httpsWatchdog?.cancel()
        httpsWatchdog = nil
    }

    private func fallBackToHTTP() {
        guard let insecure = pendingHTTPFallback, let view = liveWebView else { return }
        settleHTTPS()
        view.stopLoading()
        view.load(URLRequest(url: insecure))
        owner?.tabFellBackToHTTP(self)
    }

    /// Échecs qui veulent dire « pas de HTTPS ici » ; une adresse introuvable (DNS) échouerait aussi en HTTP.
    static func meansNoHTTPS(_ error: any Error) -> Bool {
        let error = error as NSError
        guard error.domain == NSURLErrorDomain else { return false }
        let codes: Set<Int> = [NSURLErrorTimedOut, NSURLErrorCannotConnectToHost, NSURLErrorNetworkConnectionLost,
                               NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateHasBadDate,
                               NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasUnknownRoot,
                               NSURLErrorServerCertificateNotYetValid, NSURLErrorClientCertificateRejected,
                               NSURLErrorClientCertificateRequired]
        return codes.contains(error.code)
    }

    /// La vue de la page ; réveille l'onglet s'il dormait.
    var webView: WKWebView {
        if let liveWebView { return liveWebView }
        let view = makeWebView(configuration: nil)
        if let savedInteractionState {
            view.interactionState = savedInteractionState
            self.savedInteractionState = nil
        } else if let url {
            if url.isFileURL { view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent()) }
            else { view.load(URLRequest(url: url)); armHTTPSWatchdog() }
        }
        return view
    }

    @discardableResult
    private func makeWebView(configuration: WKWebViewConfiguration?) -> WKWebView {
        let config = configuration ?? (host.map { Self.makeConfiguration(space: space, host: $0) } ?? WKWebViewConfiguration())
        let view = WKWebView(frame: .zero, configuration: config)
        view.isInspectable = true
        view.allowsBackForwardNavigationGestures = true
        view.allowsMagnification = true
        view.navigationDelegate = self
        view.uiDelegate = self
        observations = [
            view.observe(\.url, options: [.old]) { [weak self] _, change in
                MainActor.assumeIsolated { self?.urlDidChange(old: change.oldValue ?? nil) }
            },
            view.observe(\.title) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.titleDidChange() }
            },
            view.observe(\.isLoading) { [weak self] view, _ in
                MainActor.assumeIsolated {
                    self?.propertiesDidChange([.loading])
                    if let self { self.owner?.tabLoadingDidChange(self) }
                    if !view.isLoading, let self { self.owner?.tabDidFinishLoading(self) }
                }
            },
            // Progression du chargement : le trait du haut s'élargit avec elle.
            view.observe(\.estimatedProgress) { [weak self] _, _ in
                MainActor.assumeIsolated { if let self { self.owner?.tabLoadingDidChange(self) } }
            },
        ]
        liveWebView = view
        return view
    }

    static func makeConfiguration(space: Space, host: ExtensionHost) -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = space.store
        config.webExtensionController = host.controller
        // Les sites voient un navigateur WebKit standard (sinon certains servent une version dégradée).
        config.applicationNameForUserAgent = "Version/26.0 Safari/605.1.15"
        config.preferences.isElementFullscreenEnabled = true
        CopyRelay.install(on: config)
        ExtensionDebugConsole.installIfEnabled(on: config)
        return config
    }

    // MARK: Veille et captures

    /// Endort l'onglet : état de navigation gardé, vue relâchée.
    /// La capture a déjà été prise quand la page a quitté l'écran (une vue masquée ne se capture pas).
    func sleep() {
        guard let view = liveWebView, view.superview == nil || view.isHidden else { return }
        savedInteractionState = view.interactionState
        observations = []
        view.stopLoading()
        view.navigationDelegate = nil
        view.uiDelegate = nil
        view.removeFromSuperview()
        liveWebView = nil
    }

    /// Ferme la page sans retirer l'onglet (⌘W sur un épinglé) : vue relâchée, historique oublié, et l'onglet
    /// rouvrira sur son adresse épinglée.
    func unload() {
        settleHTTPS()
        if let view = liveWebView {
            observations = []
            view.stopLoading()
            view.navigationDelegate = nil
            view.uiDelegate = nil
            view.removeFromSuperview()
            liveWebView = nil
        }
        savedInteractionState = nil
        if let homeURL, homeURL != url {
            previousURL = url
            url = homeURL
            title = nil
            SnapshotStore.shared.forget(id)
        }
    }

    /// Capture avec délai maximal : si WebKit ne répond pas (fenêtre cachée), on continue sans attendre.
    func captureSnapshot(timeout: Duration) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let gate = OnceGate(continuation)
            Task { await self.captureSnapshot(); gate.open() }
            Task { try? await Task.sleep(for: timeout); gate.open() }
        }
    }

    /// Capture réduite de la page affichée (cartes des vues d'onglets).
    func captureSnapshot() async {
        guard let view = liveWebView, view.window != nil, !view.isHidden, view.bounds.width > 0 else { return }
        let config = WKSnapshotConfiguration()
        config.snapshotWidth = 640
        config.afterScreenUpdates = false
        if let image = try? await view.takeSnapshot(configuration: config) {
            SnapshotStore.shared.store(image, for: id)
        }
    }

    // MARK: Changements de la page

    private func urlDidChange(old: URL?) {
        guard let newURL = liveWebView?.url else { return }
        previousURL = old ?? url
        url = newURL
        propertiesDidChange([.URL])
        owner?.tabDidChangeURL(self)
    }

    private func titleDidChange() {
        if let newTitle = liveWebView?.title, !newTitle.isEmpty { title = newTitle }
        propertiesDidChange([.title])
        owner?.tabDidChangeTitle(self)
    }

    private func propertiesDidChange(_ properties: WKWebExtension.TabChangedProperties) {
        host?.controller.didChangeTabProperties(properties, for: self)
    }

    // MARK: WKWebExtensionTab

    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? { owner }
    func indexInWindow(for context: WKWebExtensionContext) -> Int { owner?.index(of: self) ?? 0 }
    /// Un onglet endormi n'a pas de page : l'extension n'a rien à y injecter.
    func webView(for context: WKWebExtensionContext) -> WKWebView? { liveWebView }
    func title(for context: WKWebExtensionContext) -> String? { title }
    func url(for context: WKWebExtensionContext) -> URL? { url }
    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool { !(liveWebView?.isLoading ?? false) }
    func isSelected(for context: WKWebExtensionContext) -> Bool { owner?.activeTab === self }
    func zoomFactor(for context: WKWebExtensionContext) -> Double { Double(liveWebView?.pageZoom ?? 1) }

    func activate(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        owner?.select(self)
        completionHandler(nil)
    }

    func loadURL(_ url: URL, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        webView.load(URLRequest(url: url))
        completionHandler(nil)
    }

    func reload(fromOrigin: Bool, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        guard let view = liveWebView else { _ = webView; return completionHandler(nil) }  // le réveil recharge
        _ = fromOrigin ? view.reloadFromOrigin() : view.reload()
        completionHandler(nil)
    }

    func goBack(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        _ = liveWebView?.goBack(); completionHandler(nil)
    }

    func goForward(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        _ = liveWebView?.goForward(); completionHandler(nil)
    }

    func close(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        owner?.close(self)
        completionHandler(nil)
    }

    // MARK: Navigation

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        // Cmd+clic sur un lien : nouvel onglet en arrière-plan, comme dans tous les navigateurs.
        if navigationAction.navigationType == .linkActivated, navigationAction.modifierFlags.contains(.command),
           let url = navigationAction.request.url {
            owner?.newTab(url: url, in: space, activate: navigationAction.modifierFlags.contains(.shift))
            decisionHandler(.cancel)
            return
        }
        decisionHandler(navigationAction.shouldPerformDownload ? .download : .allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
        if navigationResponse.isForMainFrame { settleHTTPS() }
        // Ce que WebKit ne sait pas afficher (PDF exclus) est téléchargé.
        decisionHandler(navigationResponse.canShowMIMEType ? .allow : .download)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        if pendingHTTPFallback != nil, Self.meansNoHTTPS(error) { fallBackToHTTP() } else { settleHTTPS() }
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = DownloadManager.shared
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = DownloadManager.shared
    }

    // MARK: Interface demandée par la page

    /// `target=_blank` et `window.open` : nouvel onglet, dans le même espace, avec la configuration fournie par WebKit.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        owner?.newTab(configuration: configuration, from: self).webView
    }

    func webViewDidClose(_ webView: WKWebView) {
        owner?.close(self)
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor () -> Void) {
        let alert = pageAlert(message, frame: frame)
        alert.addButton(withTitle: "OK")
        present(alert) { _ in completionHandler() }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (Bool) -> Void) {
        let alert = pageAlert(message, frame: frame)
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Annuler")
        present(alert) { completionHandler($0 == .alertFirstButtonReturn) }
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (String?) -> Void) {
        let alert = pageAlert(prompt, frame: frame)
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = defaultText ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Annuler")
        present(alert) { completionHandler($0 == .alertFirstButtonReturn ? field.stringValue : nil) }
    }

    /// Envoi de fichiers dans un formulaire.
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        guard let window = webView.window else { return completionHandler(nil) }
        panel.beginSheetModal(for: window) { response in
            completionHandler(response == .OK ? panel.urls : nil)
        }
    }

    private func pageAlert(_ text: String, frame: WKFrameInfo) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = DomainPolicy.displayHost(for: frame.request.url) ?? "Cette page"
        alert.informativeText = text
        return alert
    }

    private func present(_ alert: NSAlert, completion: @escaping @MainActor (NSApplication.ModalResponse) -> Void) {
        if let window = liveWebView?.window { alert.beginSheetModal(for: window, completionHandler: completion) }
        else { completion(alert.runModal()) }
    }
}

/// Téléchargements : enregistrés dans ~/Téléchargements, sans écraser un fichier existant.
@MainActor
final class DownloadManager: NSObject, WKDownloadDelegate {
    static let shared = DownloadManager()
    var onFinished: ((URL) -> Void)?
    private var destinations: [ObjectIdentifier: URL] = [:]

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String,
                  completionHandler: @escaping @MainActor (URL?) -> Void) {
        let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let destination = Self.uniqueURL(in: folder, for: suggestedFilename)
        destinations[ObjectIdentifier(download)] = destination
        completionHandler(destination)
    }

    func downloadDidFinish(_ download: WKDownload) {
        if let url = destinations.removeValue(forKey: ObjectIdentifier(download)) { onFinished?(url) }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        destinations.removeValue(forKey: ObjectIdentifier(download))
        NSLog("Vision Browser : téléchargement échoué : \(error.localizedDescription)")
    }

    static func uniqueURL(in folder: URL, for name: String) -> URL {
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        var candidate = folder.appendingPathComponent(name)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        return candidate
    }
}

/// Reprend une attente une seule fois, quel que soit le premier arrivé.
@MainActor
private final class OnceGate {
    private var continuation: CheckedContinuation<Void, Never>?
    init(_ continuation: CheckedContinuation<Void, Never>) { self.continuation = continuation }
    func open() {
        continuation?.resume()
        continuation = nil
    }
}
