import WebKit

/// La fenêtre de navigation : la page occupe toute la fenêtre (F1), aucune interface permanente.
/// Gère les onglets, les surcouches (barre d'adresse, indicateur de domaine) et expose la fenêtre
/// à l'extension (`WKWebExtensionWindow`).
@MainActor
final class BrowserWindowController: NSWindowController, NSWindowDelegate, WKWebExtensionWindow {
    let host: ExtensionHost
    private let space = Space.personal
    private let sessionStore: SessionStore

    private(set) var tabs: [BrowserTab] = []
    private(set) var activeTab: BrowserTab?
    /// Adresses des onglets fermés, pour ⇧⌘T.
    private var closedURLs: [URL] = []

    private let pageContainer = NSView()
    private let commandBar = CommandBarView()
    private let domainToast = DomainToastView()
    private let insecureStripe = PassthroughView()
    private let trafficLightZone = TrafficLightZone()
    /// Point d'ancrage du popup Bitwarden (coin supérieur droit).
    let popupAnchor = PassthroughView()

    private var saveTask: Task<Void, Never>?
    /// Historique et favoris (phase 2) ; nil si la base ne s'ouvre pas : le navigateur reste utilisable.
    private let places = PlacesStore.openDefault()
    private lazy var engine = CommandBarEngine(places: places)
    private var suggestionTask: Task<Void, Never>?
    private var keyMonitor: Any?

    init(host: ExtensionHost, session: SessionStore) {
        self.host = host
        self.sessionStore = session
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1360, height: 880),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = false
        window.setFrameAutosaveName("VisionBrowserMainWindow")
        if window.frame.origin == .zero { window.center() }
        window.title = "Vision Browser"
        super.init(window: window)
        window.delegate = self
        buildInterface()
        host.window = self
        DownloadManager.shared.onFinished = { [weak self] url in
            self?.domainToast.show(text: "Téléchargé : \(url.lastPathComponent)", symbol: "arrow.down.circle.fill", tint: .systemBlue)
        }
        host.controller.didOpenWindow(self)
        host.controller.didFocusWindow(self)
        installControlTabShortcut()
    }

    /// Ctrl+Tab / Ctrl+Maj+Tab : macOS traite la touche Tab avant la fenêtre et les menus
    /// (navigation au clavier), un raccourci de menu ne se déclenche donc jamais.
    /// Un moniteur local voit la touche avant tout traitement.
    private func installControlTabShortcut() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 48, event.modifierFlags.contains(.control),
                  let self, event.window === self.window else { return event }
            MainActor.assumeIsolated { self.cycleTabs(by: event.modifierFlags.contains(.shift) ? -1 : 1) }
            return nil
        }
    }

    required init?(coder: NSCoder) { fatalError("non utilisé") }

    // MARK: Interface

    private func buildInterface() {
        guard let window, let content = window.contentView else { return }
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let dragStrip = WindowDragStrip()
        insecureStripe.wantsLayer = true
        insecureStripe.layer?.backgroundColor = NSColor.systemRed.cgColor
        insecureStripe.isHidden = true

        for view in [pageContainer, dragStrip, insecureStripe, domainToast, commandBar, trafficLightZone, popupAnchor] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            pageContainer.topAnchor.constraint(equalTo: content.topAnchor),
            pageContainer.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            pageContainer.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            pageContainer.trailingAnchor.constraint(equalTo: content.trailingAnchor),

            // Bande invisible de 10 px en haut : on peut déplacer la fenêtre en la saisissant.
            dragStrip.topAnchor.constraint(equalTo: content.topAnchor),
            dragStrip.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 90),
            dragStrip.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            dragStrip.heightAnchor.constraint(equalToConstant: 10),

            insecureStripe.topAnchor.constraint(equalTo: content.topAnchor),
            insecureStripe.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            insecureStripe.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            insecureStripe.heightAnchor.constraint(equalToConstant: 3),

            domainToast.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            domainToast.centerXAnchor.constraint(equalTo: content.centerXAnchor),

            commandBar.topAnchor.constraint(equalTo: content.topAnchor, constant: 90),
            commandBar.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            commandBar.widthAnchor.constraint(equalTo: content.widthAnchor, multiplier: 0.5, constant: 160),
            commandBar.widthAnchor.constraint(lessThanOrEqualToConstant: 760),

            trafficLightZone.topAnchor.constraint(equalTo: content.topAnchor),
            trafficLightZone.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            trafficLightZone.widthAnchor.constraint(equalToConstant: 90),
            trafficLightZone.heightAnchor.constraint(equalToConstant: 36),

            popupAnchor.topAnchor.constraint(equalTo: content.topAnchor, constant: 8),
            popupAnchor.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            popupAnchor.widthAnchor.constraint(equalToConstant: 1),
            popupAnchor.heightAnchor.constraint(equalToConstant: 1),
        ])

        // Boutons rouge/jaune/vert cachés, visibles au survol du coin supérieur gauche.
        trafficLightZone.onHover = { [weak self] inside in self?.setTrafficLightsVisible(inside) }
        setTrafficLightsVisible(false)

        commandBar.isHidden = true
        commandBar.onQueryChange = { [weak self] query in self?.refreshResults(for: query) }
        commandBar.onExecute = { [weak self] result, typed, invert in self?.execute(result, typed: typed, invert: invert) }
        commandBar.onCancel = { [weak self] in self?.hideCommandBar() }
    }

    private func setTrafficLightsVisible(_ visible: Bool) {
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window?.standardWindowButton(kind)?.animator().alphaValue = visible ? 1 : 0
        }
    }

    // MARK: Session

    func restoreSession(extraURLs: [URL]) {
        let snapshot = sessionStore.load()
        snapshot.tabs.forEach { newTab(url: $0.url, activate: false) }
        if tabs.indices.contains(snapshot.activeIndex) { select(tabs[snapshot.activeIndex]) }
        extraURLs.forEach { newTab(url: $0, activate: true) }
        if tabs.isEmpty { newTabAction(nil) }
    }

    func scheduleSessionSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.saveSessionNow()
        }
    }

    func saveSessionNow() {
        let records = tabs.compactMap { tab in tab.url.map { SessionSnapshot.TabRecord(url: $0, title: tab.title) } }
        let index = activeTab.flatMap { active in tabs.filter { $0.url != nil }.firstIndex { $0 === active } } ?? 0
        sessionStore.save(SessionSnapshot(tabs: records, activeIndex: index))
    }

    // MARK: Onglets

    @discardableResult
    func newTab(url: URL?, activate: Bool) -> BrowserTab {
        let tab = BrowserTab(space: space, host: host)
        insert(tab, activate: activate)
        if let url {
            if url.isFileURL { tab.webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent()) }
            else { tab.webView.load(URLRequest(url: url)) }
        }
        return tab
    }

    /// Onglet demandé par une page (`target=_blank`, `window.open`).
    func newTab(configuration: WKWebViewConfiguration, request: URLRequest) -> BrowserTab? {
        let tab = BrowserTab(space: space, host: host, configuration: configuration)
        insert(tab, activate: true)
        return tab
    }

    private func insert(_ tab: BrowserTab, activate: Bool) {
        tab.owner = self
        let position = activeTab.flatMap { active in tabs.firstIndex { $0 === active } }.map { $0 + 1 } ?? tabs.count
        tabs.insert(tab, at: position)
        host.controller.didOpenTab(tab)
        if activate || activeTab == nil { select(tab) }
        scheduleSessionSave()
    }

    func select(_ tab: BrowserTab) {
        guard tab !== activeTab else { return }
        let previous = activeTab
        activeTab = tab
        tab.lastActivated = Date()
        pageContainer.subviews.forEach { $0.removeFromSuperview() }
        tab.webView.translatesAutoresizingMaskIntoConstraints = false
        pageContainer.addSubview(tab.webView)
        NSLayoutConstraint.activate([
            tab.webView.topAnchor.constraint(equalTo: pageContainer.topAnchor),
            tab.webView.bottomAnchor.constraint(equalTo: pageContainer.bottomAnchor),
            tab.webView.leadingAnchor.constraint(equalTo: pageContainer.leadingAnchor),
            tab.webView.trailingAnchor.constraint(equalTo: pageContainer.trailingAnchor),
        ])
        window?.makeFirstResponder(tab.webView)
        host.controller.didActivateTab(tab, previousActiveTab: previous)
        updateChrome(announce: true)
        scheduleSessionSave()
    }

    func close(_ tab: BrowserTab) {
        guard let index = tabs.firstIndex(where: { $0 === tab }) else { return }
        if let url = tab.url { closedURLs.append(url) }
        tabs.remove(at: index)
        host.controller.didCloseTab(tab, windowIsClosing: false)
        tab.webView.removeFromSuperview()
        if tab === activeTab {
            activeTab = nil
            if tabs.isEmpty { newTabAction(nil) }
            else { select(tabs[min(index, tabs.count - 1)]) }
        }
        scheduleSessionSave()
    }

    func index(of tab: BrowserTab) -> Int { tabs.firstIndex { $0 === tab } ?? 0 }

    func tabDidChangeURL(_ tab: BrowserTab) {
        if let url = tab.url { places?.recordVisit(url: url, title: tab.title) }
        if tab === activeTab { updateChrome(announce: DomainPolicy.shouldAnnounce(previous: tab.previousURL, next: tab.url)) }
        scheduleSessionSave()
    }

    func tabDidChangeTitle(_ tab: BrowserTab) {
        if let url = tab.url, let title = tab.title { places?.updateTitle(url: url, title: title) }
        if tab === activeTab { window?.title = tab.title ?? "Vision Browser" }
    }

    /// Indicateur de domaine et liseré « non sécurisé ».
    private func updateChrome(announce: Bool) {
        let url = activeTab?.url
        insecureStripe.isHidden = !DomainPolicy.isInsecure(url)
        window?.title = activeTab?.title ?? "Vision Browser"
        if announce, let host = DomainPolicy.displayHost(for: url) {
            let secure = !DomainPolicy.isInsecure(url)
            domainToast.show(text: host, symbol: secure ? "lock.fill" : "exclamationmark.triangle.fill", tint: secure ? .systemGreen : .systemRed)
        }
    }

    // MARK: Barre de commande (Cmd+T / Cmd+L)

    private func showCommandBar(newTab: Bool) {
        commandBar.present(text: newTab ? "" : (activeTab?.url?.absoluteString ?? ""), newTab: newTab)
        window?.makeFirstResponder(commandBar.field)
        refreshResults(for: commandBar.query)
    }

    private func hideCommandBar() {
        suggestionTask?.cancel()
        commandBar.isHidden = true
        if let webView = activeTab?.webView { window?.makeFirstResponder(webView) }
    }

    private var openTabInfos: [OpenTabInfo] {
        tabs.map { OpenTabInfo(id: $0.id, url: $0.url, title: $0.title, space: space.name, lastActivated: $0.lastActivated) }
    }

    private var commandContext: CommandBarEngine.Context {
        .init(activeURL: activeTab?.url, activeIsFavorite: activeTab?.url.map { places?.isFavorite($0) ?? false } ?? false)
    }

    /// Résultats locaux immédiatement, puis suggestions du moteur de recherche dès qu'elles arrivent.
    private func refreshResults(for query: String) {
        commandBar.show(results: engine.results(for: query, tabs: openTabInfos, context: commandContext))
        suggestionTask?.cancel()
        guard case .search? = AddressInput.parse(query) else { return }
        suggestionTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            let suggestions = await SearchSuggestions.fetch(query)
            guard !Task.isCancelled, let self, !self.commandBar.isHidden, self.commandBar.query == query else { return }
            self.commandBar.show(results: self.engine.results(for: query, tabs: self.openTabInfos, context: self.commandContext,
                                                             suggestions: suggestions), keepSelection: true)
        }
    }

    /// Exécute le résultat choisi. `invert` (Cmd+Entrée) inverse « nouvel onglet » et « onglet actuel ».
    private func execute(_ result: CommandResult?, typed: String, invert: Bool) {
        let inNewTab = commandBar.isNewTab != invert
        hideCommandBar()
        guard let result else {
            if let input = AddressInput.parse(typed) { open(input.url, inNewTab: inNewTab) }
            return
        }
        switch result.kind {
        case .openTab(let id, _):
            if let tab = tabs.first(where: { $0.id == id }) { select(tab) }
        case .command(.copyAddress):
            guard let url = activeTab?.url else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.absoluteString, forType: .string)
            domainToast.show(text: "Adresse copiée", symbol: "doc.on.doc.fill", tint: .systemOrange)
        case .command(.toggleFavorite):
            toggleFavoriteForActiveTab()
        case .favorite, .history, .address, .search, .suggestion:
            if let url = result.url { open(url, inNewTab: inNewTab) }
        }
    }

    private func open(_ url: URL, inNewTab: Bool) {
        if inNewTab || activeTab == nil { newTab(url: url, activate: true) }
        else { activeTab?.webView.load(URLRequest(url: url)) }
    }

    private func toggleFavoriteForActiveTab() {
        guard let tab = activeTab, let url = tab.url, let places else { return }
        let added = places.toggleFavorite(url: url, title: tab.title)
        domainToast.show(text: added ? "Ajouté aux favoris" : "Retiré des favoris", symbol: added ? "star.fill" : "star.slash", tint: .systemYellow)
    }

    // MARK: Actions (menus et raccourcis)

    @objc func newTabAction(_ sender: Any?) { showCommandBar(newTab: true) }
    @objc func editAddressAction(_ sender: Any?) { showCommandBar(newTab: false) }
    @objc func toggleFavoriteAction(_ sender: Any?) { toggleFavoriteForActiveTab() }
    @objc func closeTabAction(_ sender: Any?) {
        if !commandBar.isHidden { return hideCommandBar() }
        if let activeTab { close(activeTab) }
    }
    @objc func reopenClosedTabAction(_ sender: Any?) {
        if let url = closedURLs.popLast() { newTab(url: url, activate: true) }
    }
    @objc func reloadAction(_ sender: Any?) { activeTab?.webView.reload() }
    @objc func goBackAction(_ sender: Any?) { activeTab?.webView.goBack() }
    @objc func goForwardAction(_ sender: Any?) { activeTab?.webView.goForward() }
    @objc func zoomInAction(_ sender: Any?) { activeTab.map { $0.webView.pageZoom = min($0.webView.pageZoom + 0.1, 3) } }
    @objc func zoomOutAction(_ sender: Any?) { activeTab.map { $0.webView.pageZoom = max($0.webView.pageZoom - 0.1, 0.3) } }
    @objc func zoomResetAction(_ sender: Any?) { activeTab?.webView.pageZoom = 1 }
    @objc func nextTabAction(_ sender: Any?) { cycleTabs(by: 1) }
    @objc func previousTabAction(_ sender: Any?) { cycleTabs(by: -1) }
    @objc func selectTabByNumberAction(_ sender: Any?) {
        guard let n = (sender as? NSMenuItem)?.tag, !tabs.isEmpty else { return }
        select(n == 9 ? tabs[tabs.count - 1] : tabs[min(n - 1, tabs.count - 1)])
    }
    @objc func openBitwardenAction(_ sender: Any?) { host.performAction(for: activeTab) }

    private func cycleTabs(by step: Int) {
        guard let activeTab, let i = tabs.firstIndex(where: { $0 === activeTab }), tabs.count > 1 else { return }
        select(tabs[(i + step + tabs.count) % tabs.count])
    }

    // MARK: NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) { host.controller.didFocusWindow(self) }

    func windowWillClose(_ notification: Notification) {
        saveSessionNow()
        host.controller.didCloseWindow(self)
    }

    // MARK: WKWebExtensionWindow

    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] { tabs }
    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? { activeTab }
    func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType { .normal }
    func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState {
        guard let window else { return .normal }
        if window.styleMask.contains(.fullScreen) { return .fullscreen }
        return window.isMiniaturized ? .minimized : .normal
    }
    func isPrivate(for context: WKWebExtensionContext) -> Bool { false }
    func frame(for context: WKWebExtensionContext) -> CGRect { window?.frame ?? .zero }
    func screenFrame(for context: WKWebExtensionContext) -> CGRect { window?.screen?.frame ?? .zero }
    func focus(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        window?.makeKeyAndOrderFront(nil)
        completionHandler(nil)
    }
}
