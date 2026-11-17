import WebKit

/// Ce que la page d'accueil a besoin de savoir du navigateur, et ce qu'elle peut lui demander.
@MainActor
protocol HomePageHost: AnyObject {
    var homeSpaces: [(id: UUID, name: String, colorIndex: Int)] { get }
    var homeCurrentSpaceID: UUID { get }
    /// Onglets ouverts (tous espaces, récents d'abord), proposés pour « Lier une page ».
    var homeOpenTabs: [(title: String, url: URL, space: String)] { get }
    /// Ouvre une page liée à une tâche dans l'espace affiché.
    func homeOpen(_ url: URL)
}

/// La page d'accueil (espace sans onglet) : la gestion des tâches, direction « La salle ».
///
/// Une page HTML de l'app (`Resources/Home/accueil.html`), servie sous `vision://accueil` et affichée dans sa
/// propre vue web. Pourquoi une page plutôt que des vues AppKit : le tableau à lignes dépliables, le texte
/// modifiable et les animations de la maquette se reprennent tels quels.
///
/// Sécurité : cette vue a sa configuration à elle (aucun onglet ne la partage), un coffre de données éphémère,
/// une politique qui interdit toute ressource extérieure, et le canal `vision` ne répond qu'à la page `vision://`
/// du cadre principal. Un lien vers le web n'est jamais suivi ici : il s'ouvre dans un onglet.
@MainActor
final class HomePage: NSObject, WKURLSchemeHandler, WKScriptMessageHandlerWithReply, WKNavigationDelegate {
    static let scheme = "vision"
    static let url = URL(string: "vision://accueil")!
    private static let prefsKey = "VBHomePrefs"

    weak var host: HomePageHost?
    private let store: TaskStore?
    private(set) lazy var webView: WKWebView = makeWebView()
    private var loaded = false

    init(store: TaskStore? = TaskStore.openDefault()) {
        self.store = store
        super.init()
    }

    private func makeWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.setURLSchemeHandler(self, forURLScheme: Self.scheme)
        config.userContentController.addScriptMessageHandler(self, contentWorld: .page, name: "vision")
        // Échap : même règle que sur les pages (la Scène s'ouvre si la page ne s'en sert pas, ex. champ actif).
        EscapeRelay.install(on: config)
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = self
        view.setValue(false, forKey: "drawsBackground")
        view.underPageBackgroundColor = Design.Palette.house
        return view
    }

    /// Charge la page la première fois, sinon lui redonne l'état (tâches modifiées ailleurs, autre espace affiché).
    func show(space: UUID) {
        if !loaded {
            loaded = true
            webView.load(URLRequest(url: Self.url))
        } else {
            webView.evaluateJavaScript("window.visionHome && visionHome.refresh('\(space.uuidString)')")
        }
    }

    func focusAddField() {
        webView.evaluateJavaScript("window.visionHome && visionHome.focusAdd()")
    }

    // MARK: Page servie par l'app

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard task.request.url?.host == "accueil",
              let file = Bundle.main.url(forResource: "accueil", withExtension: "html"),
              let data = try? Data(contentsOf: file) else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        task.didReceive(URLResponse(url: task.request.url!, mimeType: "text/html", expectedContentLength: data.count, textEncodingName: "utf-8"))
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}

    /// Seule la page interne se charge ici ; un lien web part dans un onglet.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = action.request.url else { return .cancel }
        if url.scheme == Self.scheme { return .allow }
        if ["http", "https"].contains(url.scheme?.lowercased() ?? "") { host?.homeOpen(url) }
        return .cancel
    }

    // MARK: Canal avec la page

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) async -> (Any?, String?) {
        guard message.frameInfo.isMainFrame, message.frameInfo.securityOrigin.protocol == Self.scheme,
              let body = message.body as? [String: Any], let name = body["name"] as? String else { return (nil, "refusé") }
        let args = body["args"] as? [String: Any] ?? [:]
        return (handle(name, args), nil)
    }

    /// Exécute une demande de la page ; renvoie du JSON (l'état complet après une modification).
    func handle(_ name: String, _ args: [String: Any]) -> String? {
        let id = (args["id"] as? NSNumber)?.int64Value ?? 0
        switch name {
        case "state":
            break
        case "parse":
            return Self.json(QuickTask.parse(args["text"] as? String ?? "", today: Date()).asDictionary)
        case "add":
            let quick = QuickTask.parse(args["text"] as? String ?? "", today: Date())
            let space = args["spaceID"] as? String ?? host?.homeCurrentSpaceID.uuidString
            store?.add(title: quick.title, project: quick.project ?? "", sub: quick.sub ?? "", spaceID: space, due: quick.due)
        case "update":
            if let raw = args["changes"], let data = try? JSONSerialization.data(withJSONObject: raw),
               let changes = try? JSONDecoder().decode(TaskStore.Changes.self, from: data) {
                store?.update(id, changes)
            }
        case "delete":
            store?.delete(id)
        case "addSub":
            store?.addSubtask(to: id, title: args["title"] as? String ?? "")
        case "setSub":
            store?.setSubtask(id, done: args["done"] as? Bool ?? false)
        case "deleteSub":
            store?.deleteSubtask(id)
        case "addLink":
            if let url = Self.webURL(args["url"] as? String) {
                store?.addLink(to: id, url: url, title: args["title"] as? String ?? "")
            }
        case "deleteLink":
            store?.deleteLink(id)
        case "open":
            if let url = Self.webURL(args["url"] as? String) { host?.homeOpen(url) }
            return nil
        case "prefs":
            var prefs = UserDefaults.standard.dictionary(forKey: Self.prefsKey) ?? [:]
            for key in ["mode", "groupBy", "sortBy", "scope"] { if let value = args[key] as? String { prefs[key] = value } }
            UserDefaults.standard.set(prefs, forKey: Self.prefsKey)
            return nil
        default:
            return nil
        }
        return state()
    }

    /// L'état complet que la page affiche.
    func state() -> String? {
        let spaces = host?.homeSpaces ?? []
        let current = host?.homeCurrentSpaceID
        let payload: [String: Any] = [
            "today": QuickTask.dayString(Date()),
            "space": spaces.first { $0.id == current }.map { ["id": $0.id.uuidString, "name": $0.name] } ?? NSNull(),
            "spaces": spaces.map { ["id": $0.id.uuidString, "name": $0.name, "color": Self.hex(Design.Palette.spacePigments[$0.colorIndex % Design.Palette.spacePigments.count])] },
            "tasks": (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(store?.all() ?? []))) ?? [],
            "tabs": (host?.homeOpenTabs ?? []).map { ["title": $0.title, "url": $0.url.absoluteString, "space": $0.space] },
            "prefs": UserDefaults.standard.dictionary(forKey: Self.prefsKey) ?? [:],
        ]
        return Self.json(payload)
    }

    private static func json(_ object: Any) -> String? {
        (try? JSONSerialization.data(withJSONObject: object)).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// Une adresse web tapée ou collée (`exemple.fr/page` devient `https://exemple.fr/page`).
    static func webURL(_ text: String?) -> URL? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        if case .url(let url) = AddressInput.parse(text), ["http", "https"].contains(url.scheme?.lowercased() ?? "") { return url }
        return nil
    }

    private static func hex(_ value: UInt32) -> String { String(format: "#%06x", value) }
}

private extension QuickTask {
    var asDictionary: [String: Any] {
        ["title": title, "project": project ?? NSNull(), "sub": sub ?? NSNull(), "due": due ?? NSNull()]
    }
}
