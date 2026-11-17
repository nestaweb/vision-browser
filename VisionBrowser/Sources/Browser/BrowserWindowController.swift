import WebKit

/// La fenêtre de navigation : la page occupe toute la fenêtre (F1), aucune interface permanente.
/// Gère les espaces (F5) et leurs onglets, les surcouches (barre Cmd+T, indicateur de domaine)
/// et expose la fenêtre à l'extension (`WKWebExtensionWindow`).
@MainActor
final class BrowserWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation, WKWebExtensionWindow {
    let host: ExtensionHost
    private let sessionStore: SessionStore
    private let spacesStore: SpacesStore

    // MARK: Espaces et onglets

    private(set) var config: SpacesConfig
    private(set) var spaces: [Space]
    private(set) var currentSpace: Space
    private var tabsBySpace: [UUID: [BrowserTab]] = [:]
    private var activeBySpace: [UUID: BrowserTab] = [:]
    /// Onglets fermés (adresse et espace), pour ⇧⌘T.
    private var closedTabs: [(url: URL, spaceID: UUID)] = []

    /// Onglets de l'espace affiché : Ctrl+Tab et Cmd+1…9 restent dans l'espace.
    var tabs: [BrowserTab] { tabsBySpace[currentSpace.id] ?? [] }
    /// Tous les onglets, tous espaces confondus (Cmd+T, extension).
    var allTabs: [BrowserTab] { spaces.flatMap { tabsBySpace[$0.id] ?? [] } }
    var activeTab: BrowserTab? { activeBySpace[currentSpace.id] }

    /// Appelé quand la liste des espaces ou l'espace affiché change (menu « Espaces »).
    var onSpacesChanged: (() -> Void)?

    // MARK: Interface

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

    init(host: ExtensionHost, session: SessionStore, spacesStore: SpacesStore) {
        self.host = host
        self.sessionStore = session
        self.spacesStore = spacesStore
        let config = spacesStore.load()
        self.config = config
        let spaces = config.spaces.map(Space.init(record:))
        self.spaces = spaces
        currentSpace = spaces[0]
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

    required init?(coder: NSCoder) { fatalError("non utilisé") }

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
        for saved in snapshot.spaces {
            guard let space = space(saved.spaceID) else { continue }
            saved.tabs.forEach { newTab(url: $0.url, in: space, activate: false) }
            if let list = tabsBySpace[space.id], list.indices.contains(saved.activeIndex) {
                activeBySpace[space.id] = list[saved.activeIndex]
            }
        }
        switchTo(snapshot.activeSpaceID.flatMap(space) ?? spaces[0], announce: false)
        extraURLs.forEach(openExternal)
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
        let saved = spaces.map { space -> SessionSnapshot.SpaceTabs in
            let list = (tabsBySpace[space.id] ?? []).filter { $0.url != nil }
            let active = activeBySpace[space.id].flatMap { active in list.firstIndex { $0 === active } } ?? 0
            return .init(spaceID: space.id, tabs: list.compactMap { tab in tab.url.map { .init(url: $0, title: tab.title) } },
                         activeIndex: active)
        }
        sessionStore.save(SessionSnapshot(spaces: saved, activeSpaceID: currentSpace.id))
    }

    // MARK: Espaces

    func space(_ id: UUID) -> Space? { spaces.first { $0.id == id } }

    /// Affiche un espace : son dernier onglet actif, ou la barre Cmd+T s'il est vide.
    func switchTo(_ space: Space, announce: Bool = true) {
        currentSpace = space
        if let tab = activeBySpace[space.id] ?? tabsBySpace[space.id]?.last {
            display(tab, announce: announce)
        } else {
            pageContainer.subviews.forEach { $0.removeFromSuperview() }
            updateChrome(announce: false)
            if announce { announceSpace("Espace vide", symbol: "square.dashed") }
            showCommandBar(newTab: true)
        }
        onSpacesChanged?()
        scheduleSessionSave()
    }

    @discardableResult
    func createSpace(named name: String) -> Space {
        let space = Space(record: config.addSpace(named: name))
        spaces.append(space)
        spacesStore.save(config)
        switchTo(space)
        return space
    }

    func renameCurrentSpace(to name: String) {
        config.rename(currentSpace.id, to: name)
        currentSpace.name = config.space(currentSpace.id)?.name ?? currentSpace.name
        spacesStore.save(config)
        updateWindowTitle()
        onSpacesChanged?()
    }

    /// Supprime l'espace affiché : ferme ses onglets, puis efface ses données (cookies, sessions).
    func deleteCurrentSpace() {
        let doomed = currentSpace
        guard config.remove(doomed.id) else { return }
        for tab in tabsBySpace[doomed.id] ?? [] {
            host.controller.didCloseTab(tab, windowIsClosing: false)
            tab.webView.removeFromSuperview()
        }
        tabsBySpace[doomed.id] = nil
        activeBySpace[doomed.id] = nil
        closedTabs.removeAll { $0.spaceID == doomed.id }
        spaces.removeAll { $0 === doomed }
        spacesStore.save(config)
        switchTo(spaces[0])
        // Les vues web de l'espace doivent être libérées avant d'effacer son coffre : on laisse passer un tour.
        let id = doomed.id
        Task { @MainActor in
            do { try await WKWebsiteDataStore.remove(forIdentifier: id) }
            catch { NSLog("Vision Browser : données de l'espace non effacées : \(error.localizedDescription)") }
        }
    }

    /// « Envoyer l'onglet vers… » : l'adresse est rouverte dans l'autre espace, donc avec ses cookies.
    func move(_ tab: BrowserTab, to target: Space) {
        guard tab.space !== target, let url = tab.url else { return }
        close(tab, rememberForReopen: false)
        newTab(url: url, in: target, activate: true)
        announceSpace("Rechargé avec les cookies de", symbol: "arrow.right.circle.fill")
    }

    /// Lien venant d'une autre app : l'espace désigné par une règle de routage, sinon l'espace affiché.
    func openExternal(_ url: URL) {
        let target = config.spaceID(for: url).flatMap(space) ?? currentSpace
        newTab(url: url, in: target, activate: true)
    }

    /// « Toujours ouvrir ce site ici » : règle de routage pour le domaine de l'onglet actif.
    func routeActiveHostToCurrentSpace() {
        guard let url = activeTab?.url, let host = url.host(), !host.isEmpty else { return }
        config.route(host: host, to: currentSpace.id)
        spacesStore.save(config)
        announceSpace("Les liens \(SpacesConfig.normalizedHost(host)) s'ouvriront dans", symbol: "arrow.triangle.branch")
    }

    private func announceSpace(_ text: String, symbol: String) {
        domainToast.show(text: text, symbol: symbol, tint: currentSpace.color, space: (currentSpace.name, currentSpace.color))
    }

    // MARK: Onglets

    @discardableResult
    func newTab(url: URL?, activate: Bool) -> BrowserTab { newTab(url: url, in: currentSpace, activate: activate) }

    @discardableResult
    func newTab(url: URL?, in space: Space, activate: Bool) -> BrowserTab {
        let tab = BrowserTab(space: space, host: host)
        insert(tab, activate: activate)
        if let url {
            if url.isFileURL { tab.webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent()) }
            else { tab.webView.load(URLRequest(url: url)) }
        }
        return tab
    }

    /// Onglet demandé par une page (`target=_blank`, `window.open`) : même espace que la page d'origine
    /// (la configuration fournie par WebKit porte déjà son coffre de données).
    func newTab(configuration: WKWebViewConfiguration, from opener: BrowserTab) -> BrowserTab {
        let tab = BrowserTab(space: opener.space, host: host, configuration: configuration)
        insert(tab, activate: true)
        return tab
    }

    private func insert(_ tab: BrowserTab, activate: Bool) {
        tab.owner = self
        let spaceID = tab.space.id
        var list = tabsBySpace[spaceID] ?? []
        let position = activeBySpace[spaceID].flatMap { active in list.firstIndex { $0 === active } }.map { $0 + 1 } ?? list.count
        list.insert(tab, at: position)
        tabsBySpace[spaceID] = list
        host.controller.didOpenTab(tab)
        if activate { select(tab) }
        else if activeBySpace[spaceID] == nil {
            activeBySpace[spaceID] = tab
            if tab.space === currentSpace { display(tab, announce: false) }
        }
        scheduleSessionSave()
    }

    /// Active un onglet, en basculant d'espace si besoin.
    func select(_ tab: BrowserTab) {
        activeBySpace[tab.space.id] = tab
        if tab.space !== currentSpace { return switchTo(tab.space) }
        display(tab, announce: true)
        scheduleSessionSave()
    }

    /// Met la page de l'onglet à l'écran (aucun effet si elle y est déjà).
    private func display(_ tab: BrowserTab, announce: Bool) {
        activeBySpace[tab.space.id] = tab
        tab.lastActivated = Date()
        guard tab.webView.superview !== pageContainer else { return updateChrome(announce: false) }
        let previous = allTabs.first { $0.webView.superview === pageContainer }
        pageContainer.subviews.forEach { $0.removeFromSuperview() }
        tab.webView.translatesAutoresizingMaskIntoConstraints = false
        pageContainer.addSubview(tab.webView)
        NSLayoutConstraint.activate([
            tab.webView.topAnchor.constraint(equalTo: pageContainer.topAnchor),
            tab.webView.bottomAnchor.constraint(equalTo: pageContainer.bottomAnchor),
            tab.webView.leadingAnchor.constraint(equalTo: pageContainer.leadingAnchor),
            tab.webView.trailingAnchor.constraint(equalTo: pageContainer.trailingAnchor),
        ])
        if commandBar.isHidden { window?.makeFirstResponder(tab.webView) }
        host.controller.didActivateTab(tab, previousActiveTab: previous)
        updateChrome(announce: announce)
    }

    func close(_ tab: BrowserTab) { close(tab, rememberForReopen: true) }

    private func close(_ tab: BrowserTab, rememberForReopen: Bool) {
        let spaceID = tab.space.id
        guard var list = tabsBySpace[spaceID], let index = list.firstIndex(where: { $0 === tab }) else { return }
        if rememberForReopen, let url = tab.url { closedTabs.append((url, spaceID)) }
        list.remove(at: index)
        tabsBySpace[spaceID] = list
        host.controller.didCloseTab(tab, windowIsClosing: false)
        tab.webView.removeFromSuperview()
        if activeBySpace[spaceID] === tab {
            activeBySpace[spaceID] = list.isEmpty ? nil : list[min(index, list.count - 1)]
            if tab.space === currentSpace {
                if let next = activeBySpace[spaceID] { display(next, announce: true) }
                else { updateChrome(announce: false); showCommandBar(newTab: true) }
            }
        }
        scheduleSessionSave()
    }

    func index(of tab: BrowserTab) -> Int { allTabs.firstIndex { $0 === tab } ?? 0 }

    func tabDidChangeURL(_ tab: BrowserTab) {
        if let url = tab.url { places?.recordVisit(url: url, title: tab.title) }
        if tab === activeTab { updateChrome(announce: DomainPolicy.shouldAnnounce(previous: tab.previousURL, next: tab.url)) }
        scheduleSessionSave()
    }

    func tabDidChangeTitle(_ tab: BrowserTab) {
        if let url = tab.url, let title = tab.title { places?.updateTitle(url: url, title: title) }
        if tab === activeTab { updateWindowTitle() }
    }

    /// Indicateur de domaine (avec l'espace dès qu'il y en a plusieurs) et liseré « non sécurisé ».
    private func updateChrome(announce: Bool) {
        let url = activeTab?.url
        insecureStripe.isHidden = !DomainPolicy.isInsecure(url)
        updateWindowTitle()
        if announce, let host = DomainPolicy.displayHost(for: url) {
            let secure = !DomainPolicy.isInsecure(url)
            domainToast.show(text: host, symbol: secure ? "lock.fill" : "exclamationmark.triangle.fill",
                             tint: secure ? .systemGreen : .systemRed,
                             space: spaces.count > 1 ? (currentSpace.name, currentSpace.color) : nil)
        }
    }

    /// Le titre de la fenêtre (Mission Control, menu Fenêtre) rappelle l'espace.
    private func updateWindowTitle() {
        let page = activeTab?.title.flatMap { $0.isEmpty ? nil : $0 } ?? "Vision Browser"
        window?.title = spaces.count > 1 ? "\(page) · \(currentSpace.name)" : page
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
        allTabs.map { OpenTabInfo(id: $0.id, url: $0.url, title: $0.title, space: $0.space.name, lastActivated: $0.lastActivated) }
    }

    private var commandContext: CommandBarEngine.Context {
        let url = activeTab?.url
        return .init(activeURL: url,
                     activeIsFavorite: url.map { places?.isFavorite($0) ?? false } ?? false,
                     spaces: spaces.map { .init(id: $0.id, name: $0.name) },
                     currentSpaceID: currentSpace.id,
                     routedSpaceForActiveHost: url.flatMap { config.spaceID(for: $0) })
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
            if let tab = allTabs.first(where: { $0.id == id }) { select(tab) }
        case .command(.copyAddress):
            guard let url = activeTab?.url else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.absoluteString, forType: .string)
            domainToast.show(text: "Adresse copiée", symbol: "doc.on.doc.fill", tint: .systemOrange)
        case .command(.toggleFavorite):
            toggleFavoriteForActiveTab()
        case .command(.newSpace):
            newSpaceAction(nil)
        case .command(.switchSpace(let id)):
            if let space = space(id) { switchTo(space) }
        case .command(.moveTab(let id)):
            if let tab = activeTab, let space = space(id) { move(tab, to: space) }
        case .command(.routeHostHere):
            routeActiveHostToCurrentSpace()
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

    // MARK: Dialogues d'espaces

    private func askForName(title: String, message: String, initial: String, confirm: String,
                            completion: @escaping @MainActor (String) -> Void) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = initial
        field.placeholderString = "Ex. Pro A"
        alert.accessoryView = field
        alert.addButton(withTitle: confirm)
        alert.addButton(withTitle: "Annuler")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { completion(field.stringValue) }
        }
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
        guard let last = closedTabs.popLast() else { return }
        newTab(url: last.url, in: space(last.spaceID) ?? currentSpace, activate: true)
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

    @objc func newSpaceAction(_ sender: Any?) {
        askForName(title: "Nouvel espace",
                   message: "Chaque espace a ses propres cookies et sessions : idéal pour un second compte sur le même site.",
                   initial: "", confirm: "Créer") { [weak self] name in self?.createSpace(named: name) }
    }
    @objc func renameSpaceAction(_ sender: Any?) {
        askForName(title: "Renommer l'espace « \(currentSpace.name) »", message: "", initial: currentSpace.name,
                   confirm: "Renommer") { [weak self] name in self?.renameCurrentSpace(to: name) }
    }
    @objc func deleteSpaceAction(_ sender: Any?) {
        guard spaces.count > 1, let window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Supprimer l'espace « \(currentSpace.name) » ?"
        alert.informativeText = "Ses onglets (\(tabs.count)) seront fermés et ses données (cookies, sessions, connexions) "
            + "effacées définitivement. Cette action est irréversible."
        alert.addButton(withTitle: "Supprimer")
        alert.addButton(withTitle: "Annuler")
        alert.buttons.first?.hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn { self?.deleteCurrentSpace() }
        }
    }
    @objc func switchSpaceByNumberAction(_ sender: Any?) {
        guard let n = (sender as? NSMenuItem)?.tag, spaces.indices.contains(n - 1) else { return }
        switchTo(spaces[n - 1])
    }
    @objc func moveTabToSpaceAction(_ sender: Any?) {
        guard let id = (sender as? NSMenuItem)?.representedObject as? UUID, let space = space(id), let tab = activeTab else { return }
        move(tab, to: space)
    }
    @objc func routeHostHereAction(_ sender: Any?) { routeActiveHostToCurrentSpace() }

    private func cycleTabs(by step: Int) {
        guard let activeTab, let i = tabs.firstIndex(where: { $0 === activeTab }), tabs.count > 1 else { return }
        select(tabs[(i + step + tabs.count) % tabs.count])
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(deleteSpaceAction(_:)): spaces.count > 1
        case #selector(moveTabToSpaceAction(_:)): activeTab?.url != nil
        case #selector(routeHostHereAction(_:)):
            activeTab?.url.map { config.spaceID(for: $0) != currentSpace.id && $0.host() != nil } ?? false
        case #selector(switchSpaceByNumberAction(_:)): spaces.indices.contains(item.tag - 1)
        default: true
        }
    }

    // MARK: NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) { host.controller.didFocusWindow(self) }

    func windowWillClose(_ notification: Notification) {
        saveSessionNow()
        host.controller.didCloseWindow(self)
    }

    // MARK: WKWebExtensionWindow

    /// Bitwarden voit les onglets de tous les espaces ; l'onglet actif est celui de l'espace affiché.
    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] { allTabs }
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
