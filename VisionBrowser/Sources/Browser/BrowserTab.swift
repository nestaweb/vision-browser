import WebKit
import UniformTypeIdentifiers

/// Un onglet : une page web, telle que l'utilisateur et l'extension (API `tabs.*`) la voient.
@MainActor
final class BrowserTab: NSObject, WKWebExtensionTab, WKNavigationDelegate, WKUIDelegate {
    let space: Space
    let webView: WKWebView
    weak var owner: BrowserWindowController?
    private weak var host: ExtensionHost?
    private var observations: [NSKeyValueObservation] = []
    /// URL précédente, pour savoir si le domaine a changé (indicateur de domaine).
    private(set) var previousURL: URL?

    /// - Parameter configuration: fournie par WebKit pour les fenêtres ouvertes par la page
    ///   (`target=_blank`, `window.open`) ; sinon, construite pour l'espace.
    init(space: Space, host: ExtensionHost, configuration: WKWebViewConfiguration? = nil) {
        self.space = space
        self.host = host
        let config = configuration ?? Self.makeConfiguration(space: space, host: host)
        webView = WKWebView(frame: .zero, configuration: config)
        webView.isInspectable = true
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        observations = [
            webView.observe(\.url, options: [.old]) { [weak self] _, change in
                MainActor.assumeIsolated { self?.urlDidChange(old: change.oldValue ?? nil) }
            },
            webView.observe(\.title) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.propertiesDidChange([.title]) }
            },
            webView.observe(\.isLoading) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.propertiesDidChange([.loading]) }
            },
        ]
    }

    static func makeConfiguration(space: Space, host: ExtensionHost) -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = space.store
        config.webExtensionController = host.controller
        // Les sites voient un navigateur WebKit standard (sinon certains servent une version dégradée).
        config.applicationNameForUserAgent = "Version/26.0 Safari/605.1.15"
        config.preferences.isElementFullscreenEnabled = true
        ExtensionDebugConsole.installIfEnabled(on: config)
        return config
    }

    var url: URL? { webView.url }
    var title: String? { webView.title }

    // MARK: Changements de la page

    private func urlDidChange(old: URL?) {
        previousURL = old
        propertiesDidChange([.URL])
        owner?.tabDidChangeURL(self)
    }

    private func propertiesDidChange(_ properties: WKWebExtension.TabChangedProperties) {
        host?.controller.didChangeTabProperties(properties, for: self)
        if properties.contains(.title) { owner?.tabDidChangeTitle(self) }
    }

    // MARK: WKWebExtensionTab

    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? { owner }
    func indexInWindow(for context: WKWebExtensionContext) -> Int { owner?.index(of: self) ?? 0 }
    func webView(for context: WKWebExtensionContext) -> WKWebView? { webView }
    func title(for context: WKWebExtensionContext) -> String? { webView.title }
    func url(for context: WKWebExtensionContext) -> URL? { webView.url }
    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool { !webView.isLoading }
    func isSelected(for context: WKWebExtensionContext) -> Bool { owner?.activeTab === self }
    func zoomFactor(for context: WKWebExtensionContext) -> Double { webView.pageZoom }

    func activate(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        owner?.select(self)
        completionHandler(nil)
    }

    func loadURL(_ url: URL, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        webView.load(URLRequest(url: url))
        completionHandler(nil)
    }

    func reload(fromOrigin: Bool, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        _ = fromOrigin ? webView.reloadFromOrigin() : webView.reload()
        completionHandler(nil)
    }

    func goBack(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        _ = webView.goBack(); completionHandler(nil)
    }

    func goForward(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        _ = webView.goForward(); completionHandler(nil)
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
            owner?.newTab(url: url, activate: navigationAction.modifierFlags.contains(.shift))
            decisionHandler(.cancel)
            return
        }
        decisionHandler(navigationAction.shouldPerformDownload ? .download : .allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
        // Ce que WebKit ne sait pas afficher (PDF exclus) est téléchargé.
        decisionHandler(navigationResponse.canShowMIMEType ? .allow : .download)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = DownloadManager.shared
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = DownloadManager.shared
    }

    // MARK: Interface demandée par la page

    /// `target=_blank` et `window.open` : nouvel onglet avec la configuration fournie par WebKit.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        owner?.newTab(configuration: configuration, request: navigationAction.request)?.webView
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
        if let window = webView.window { alert.beginSheetModal(for: window, completionHandler: completion) }
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
