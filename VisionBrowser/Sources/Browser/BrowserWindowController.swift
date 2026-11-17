import WebKit

/// La fenêtre de navigation : la page occupe toute la fenêtre (F1), aucune interface permanente.
/// Gère les espaces (F5) et leurs onglets, la navigation entre onglets (F2 : Ctrl+Tab, étagère, vue d'ensemble,
/// veille, archivage), les surcouches (barre Cmd+T, indicateur de domaine) et expose la fenêtre à l'extension.
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
    /// L'onglet dont la page est à l'écran.
    private var displayedTab: BrowserTab?
    /// Onglets fermés (adresse et espace), pour ⇧⌘T.
    private var closedTabs: [(url: URL, spaceID: UUID)] = []
    /// Onglets rangés automatiquement après 12 h sans consultation.
    private(set) var archived: [ArchivedTab] = []

    /// Onglets de l'espace affiché : Cmd+1…9 restent dans l'espace.
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
    private let bottomZone = BottomEdgeZone()
    private let shelf = ShelfView()
    private let overview = OverviewView()
    private let switcher = TabSwitcherView()
    private var switcherWidth: NSLayoutConstraint?
    private var switcherHeight: NSLayoutConstraint?
    /// Point d'ancrage du popup Bitwarden (coin supérieur droit).
    let popupAnchor = PassthroughView()

    private var saveTask: Task<Void, Never>?
    private var maintenanceTask: Task<Void, Never>?
    private var shelfTask: Task<Void, Never>?
    private var monitors: [Any] = []
    /// Historique et favoris (phase 2) ; nil si la base ne s'ouvre pas : le navigateur reste utilisable.
    private let places = PlacesStore.openDefault()
    private lazy var engine = CommandBarEngine(places: places)
    private var suggestionTask: Task<Void, Never>?

    // Sélecteur Ctrl+Tab
    private var switcherTabs: [BrowserTab] = []
    private var switcherIndex = 0
    private var switcherShowTask: Task<Void, Never>?
    private var pinchAccumulator: CGFloat = 0
    private var overviewOpening = false
    /// Ordre d'empilement des pages : la dernière affichée passe devant.
    private var pageLayerOrder = 0
    /// Remplissages Bitwarden en attente du chargement de leur onglet (mot de passe gardé au plus 3 min).
    private var pendingFills: [UUID: PendingFill] = [:]
    private struct PendingFill {
        var item: BitwardenItem
        var username: String?
        var password: String?
        var expires: Date
    }

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
        CopyRelay.shared.onCopy = { [weak self] webView, fromExtension in
            let tab = self?.allTabs.first { $0.liveWebView === webView }
            ClipboardMonitor.shared.checkSoon(source: fromExtension ? "Bitwarden" : DomainPolicy.displayHost(for: tab?.url),
                                              fromExtension: fromExtension)
        }
        BitwardenService.shared.onChange = { [weak self] in
            guard let self else { return }
            self.onSpacesChanged?()
            if !self.commandBar.isHidden { self.refreshResults(for: self.commandBar.query, keepSelection: true) }
        }
        ClipboardMonitor.shared.onChange = { [weak self] in
            guard let self, !self.commandBar.isHidden else { return }
            self.refreshResults(for: self.commandBar.query, keepSelection: true)
        }
        EscapeRelay.shared.onUnhandledEscape = { [weak self] webView in
            guard let self, webView != nil, webView === self.displayedTab?.liveWebView else { return }
            self.showOverview()
        }
        host.controller.didOpenWindow(self)
        host.controller.didFocusWindow(self)
        installEventMonitors()
        startMaintenance()
    }

    required init?(coder: NSCoder) { fatalError("non utilisé") }

    /// Moniteurs locaux : ils voient les événements avant la fenêtre et les menus.
    /// - Ctrl+Tab : macOS traite Tab (navigation au clavier) avant tout raccourci de menu.
    /// - Relâcher Ctrl valide le sélecteur.
    /// - Pincer pour dézoomer sur une page à 100 % ouvre la vue d'ensemble.
    private func installEventMonitors() {
        let keys = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            let consumed = MainActor.assumeIsolated { self.handleSwitcherEvent(event) }
            return consumed ? nil : event
        }
        let pinch = NSEvent.addLocalMonitorForEvents(matching: .magnify) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            let consumed = MainActor.assumeIsolated { self.handlePagePinch(event) }
            return consumed ? nil : event
        }
        monitors = [keys, pinch].compactMap { $0 }
    }

    private func buildInterface() {
        guard let window, let content = window.contentView else { return }
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let dragStrip = WindowDragStrip()
        insecureStripe.wantsLayer = true
        insecureStripe.layer?.backgroundColor = NSColor.systemRed.cgColor
        insecureStripe.isHidden = true

        for view in [pageContainer, dragStrip, insecureStripe, bottomZone, shelf, overview, switcher, domainToast, commandBar,
                     trafficLightZone, popupAnchor] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        let switcherWidth = switcher.widthAnchor.constraint(equalToConstant: 400)
        let switcherHeight = switcher.heightAnchor.constraint(equalToConstant: 190)
        self.switcherWidth = switcherWidth
        self.switcherHeight = switcherHeight
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

            bottomZone.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            bottomZone.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bottomZone.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bottomZone.heightAnchor.constraint(equalToConstant: 4),

            shelf.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
            shelf.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            shelf.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            shelf.heightAnchor.constraint(equalToConstant: ShelfView.height),

            overview.topAnchor.constraint(equalTo: content.topAnchor),
            overview.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            overview.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            overview.trailingAnchor.constraint(equalTo: content.trailingAnchor),

            switcher.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            switcher.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            switcherWidth, switcherHeight,

            domainToast.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            domainToast.centerXAnchor.constraint(equalTo: content.centerXAnchor),

            commandBar.topAnchor.constraint(equalTo: content.topAnchor, constant: 90),
            commandBar.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            // La proportion est une simple préférence, sous la priorité de taille de la fenêtre (500).
            // Plus forte, elle bornait la fenêtre à 1200 pt (0,5 × largeur + 160 ≤ 760) : AppKit en déduit
            // `maxFullScreenContentSize`, d'où des bandes noires en plein écran.
            commandBar.widthAnchor.constraint(equalTo: content.widthAnchor, multiplier: 0.5, constant: 160)
                .withPriority(NSLayoutConstraint.Priority(480)),
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

        configureShelf()
        configureOverview()
    }

    private func setTrafficLightsVisible(_ visible: Bool) {
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window?.standardWindowButton(kind)?.animator().alphaValue = visible ? 1 : 0
        }
    }

    // MARK: Session

    /// Les onglets sont recréés **endormis** : seule la page affichée se charge au lancement.
    func restoreSession(extraURLs: [URL]) {
        let snapshot = sessionStore.load()
        archived = snapshot.archived.filter { entry in spaces.contains { $0.id == entry.spaceID } }
        for saved in snapshot.spaces {
            guard let space = space(saved.spaceID) else { continue }
            for record in saved.tabs {
                let tab = BrowserTab(id: record.id, space: space, host: host, url: record.url, title: record.title,
                                     lastActivated: record.lastActivated ?? Date())
                tab.isPinned = record.pinned
                tab.homeURL = record.homeURL
                register(tab)
            }
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
            return .init(spaceID: space.id, tabs: list.compactMap { tab in
                tab.url.map { .init(id: tab.id, url: $0, title: tab.title, pinned: tab.isPinned, homeURL: tab.homeURL,
                                    lastActivated: tab.lastActivated) }
            }, activeIndex: active)
        }
        sessionStore.save(SessionSnapshot(spaces: saved, activeSpaceID: currentSpace.id, archived: archived))
        SnapshotStore.shared.prune(keeping: Set(allTabs.map(\.id)).union(archived.map(\.id)))
    }

    // MARK: Espaces

    func space(_ id: UUID) -> Space? { spaces.first { $0.id == id } }

    /// Affiche un espace : son dernier onglet actif, ou la barre Cmd+T s'il est vide.
    func switchTo(_ space: Space, announce: Bool = true) {
        currentSpace = space
        if let tab = activeBySpace[space.id] ?? tabsBySpace[space.id]?.last {
            display(tab, announce: announce)
        } else {
            retireDisplayedPage()
            updateChrome(announce: false)
            if announce { announceSpace("Espace vide", symbol: "square.dashed") }
            if overview.isHidden { showCommandBar(newTab: true) }
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
            tab.liveWebView?.removeFromSuperview()
            if displayedTab === tab { displayedTab = nil }
        }
        tabsBySpace[doomed.id] = nil
        activeBySpace[doomed.id] = nil
        closedTabs.removeAll { $0.spaceID == doomed.id }
        archived.removeAll { $0.spaceID == doomed.id }
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
    /// L'identifiant est gardé : la carte conserve sa capture.
    func move(_ tab: BrowserTab, to target: Space) {
        guard tab.space !== target, let url = tab.url else { return }
        close(tab, rememberForReopen: false)
        newTab(url: url, in: target, activate: true, id: tab.id)
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

    /// - Parameter preload: un onglet ouvert en arrière-plan (Cmd+clic) charge sa page tout de suite.
    @discardableResult
    func newTab(url: URL?, in space: Space, activate: Bool, preload: Bool = true, id: UUID = UUID()) -> BrowserTab {
        let tab = BrowserTab(id: id, space: space, host: host, url: url)
        insert(tab, activate: activate)
        if !activate && preload && url != nil { _ = tab.webView }
        return tab
    }

    /// Onglet demandé par une page (`target=_blank`, `window.open`) : même espace que la page d'origine
    /// (la configuration fournie par WebKit porte déjà son coffre de données).
    func newTab(configuration: WKWebViewConfiguration, from opener: BrowserTab) -> BrowserTab {
        let tab = BrowserTab(space: opener.space, host: host, configuration: configuration)
        insert(tab, activate: true)
        return tab
    }

    /// Ajoute l'onglet à son espace (sans l'afficher ni le charger).
    private func register(_ tab: BrowserTab, at position: Int? = nil) {
        tab.owner = self
        var list = tabsBySpace[tab.space.id] ?? []
        list.insert(tab, at: min(position ?? list.count, list.count))
        tabsBySpace[tab.space.id] = list
        host.controller.didOpenTab(tab)
    }

    private func insert(_ tab: BrowserTab, activate: Bool) {
        let spaceID = tab.space.id
        let list = tabsBySpace[spaceID] ?? []
        let position = activeBySpace[spaceID].flatMap { active in list.firstIndex { $0 === active } }.map { $0 + 1 }
        register(tab, at: position)
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

    /// Met la page de l'onglet à l'écran (la réveille si elle dormait).
    ///
    /// Les pages éveillées restent dans la fenêtre, masquées : les y remettre obligerait WebKit à tout
    /// redessiner (écran noir visible). La nouvelle page passe devant ; l'ancienne est capturée (sa carte),
    /// puis masquée. Seule la mise en veille retire une page de la fenêtre.
    private func display(_ tab: BrowserTab, announce: Bool) {
        activeBySpace[tab.space.id] = tab
        tab.lastActivated = Date()
        if tab === displayedTab, let view = tab.liveWebView, view.superview === pageContainer, !view.isHidden {
            return updateChrome(announce: false)
        }
        let previous = displayedTab
        displayedTab = tab
        let view = tab.webView
        if view.superview !== pageContainer {
            view.removeFromSuperview()
            view.translatesAutoresizingMaskIntoConstraints = false
            pageContainer.addSubview(view)
            NSLayoutConstraint.activate([
                view.topAnchor.constraint(equalTo: pageContainer.topAnchor),
                view.bottomAnchor.constraint(equalTo: pageContainer.bottomAnchor),
                view.leadingAnchor.constraint(equalTo: pageContainer.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: pageContainer.trailingAnchor),
            ])
        }
        pageLayerOrder += 1
        view.wantsLayer = true
        view.layer?.zPosition = CGFloat(pageLayerOrder)
        view.isHidden = false
        hidePages(except: view)
        if commandBar.isHidden && overview.isHidden { window?.makeFirstResponder(view) }
        host.controller.didActivateTab(tab, previousActiveTab: previous)
        updateChrome(announce: announce)
    }

    /// Masque les pages autres que `kept`, après les avoir capturées.
    private func hidePages(except kept: NSView?) {
        for other in pageContainer.subviews where other !== kept && !other.isHidden {
            let owner = allTabs.first { $0.liveWebView === other }
            Task { [weak self] in
                await owner?.captureSnapshot(timeout: .milliseconds(400))
                guard let self, other !== self.displayedTab?.liveWebView else { return }
                other.isHidden = true
            }
        }
    }

    private func retireDisplayedPage() {
        displayedTab = nil
        hidePages(except: nil)
    }

    func close(_ tab: BrowserTab) { close(tab, rememberForReopen: true) }

    private func close(_ tab: BrowserTab, rememberForReopen: Bool) {
        let spaceID = tab.space.id
        guard var list = tabsBySpace[spaceID], let index = list.firstIndex(where: { $0 === tab }) else { return }
        if rememberForReopen, let url = tab.url { closedTabs.append((url, spaceID)) }
        list.remove(at: index)
        tabsBySpace[spaceID] = list
        host.controller.didCloseTab(tab, windowIsClosing: false)
        tab.liveWebView?.removeFromSuperview()
        if displayedTab === tab { displayedTab = nil }
        if activeBySpace[spaceID] === tab {
            activeBySpace[spaceID] = TabOrganizer.recentFirst(list.map(info)).first.flatMap { info in list.first { $0.id == info.id } }
            if tab.space === currentSpace {
                if let next = activeBySpace[spaceID] { display(next, announce: true) }
                else {
                    updateChrome(announce: false)
                    if overview.isHidden { showCommandBar(newTab: true) }
                }
            }
        }
        scheduleSessionSave()
    }

    func index(of tab: BrowserTab) -> Int { allTabs.firstIndex { $0 === tab } ?? 0 }
    private func tab(_ id: UUID) -> BrowserTab? { allTabs.first { $0.id == id } }

    func tabDidChangeURL(_ tab: BrowserTab) {
        if let url = tab.url { places?.recordVisit(url: url, title: tab.title) }
        if tab === activeTab { updateChrome(announce: DomainPolicy.shouldAnnounce(previous: tab.previousURL, next: tab.url)) }
        scheduleSessionSave()
    }

    func tabDidChangeTitle(_ tab: BrowserTab) {
        if let url = tab.url, let title = tab.title { places?.updateTitle(url: url, title: title) }
        if tab === activeTab { updateWindowTitle() }
    }

    /// Page chargée : sa carte est rafraîchie peu après (le temps que la page se dessine).
    func tabDidFinishLoading(_ tab: BrowserTab) {
        if let fill = pendingFills[tab.id] {
            if fill.expires < Date() { pendingFills[tab.id] = nil } else { runFill(fill, in: tab) }
        }
        guard tab === displayedTab else { return }
        Task { [weak tab] in
            try? await Task.sleep(for: .milliseconds(600))
            await tab?.captureSnapshot()
        }
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

    // MARK: Épinglés, veille, archivage

    func setPinned(_ tab: BrowserTab, _ pinned: Bool) {
        guard tab.isPinned != pinned else { return }
        tab.isPinned = pinned
        tab.homeURL = pinned ? tab.url : nil
        domainToast.show(text: pinned ? "Épinglé dans" : "Désépinglé de", symbol: pinned ? "pin.fill" : "pin.slash",
                         tint: tab.space.color, space: (tab.space.name, tab.space.color))
        scheduleSessionSave()
    }

    /// ↺ : un onglet épinglé revient à sa page d'accueil.
    func goHome(_ tab: BrowserTab) {
        guard let home = tab.homeURL else { return }
        tab.webView.load(URLRequest(url: home))
    }

    private func reopenArchived(_ id: UUID) {
        guard let entry = archived.first(where: { $0.id == id }) else { return }
        archived.removeAll { $0.id == id }
        newTab(url: entry.url, in: space(entry.spaceID) ?? currentSpace, activate: true, id: entry.id)
    }

    /// Vérification régulière : veille des onglets inutilisés, archivage des onglets oubliés.
    private func startMaintenance() {
        let interval = min(30, max(5, TabOrganizer.sleepAfter / 4))
        maintenanceTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                self?.runMaintenance()
            }
        }
    }

    private func runMaintenance() {
        let now = Date()
        ClipboardMonitor.shared.purge(now: now)
        let infos = allTabs.map(info)
        let sleepers = TabOrganizer.sleepCandidates(infos, activeID: displayedTab?.id, now: now).compactMap(tab)
        if !sleepers.isEmpty {
            sleepers.forEach { $0.sleep() }
            let awake = allTabs.filter { !$0.isAsleep }.count
            NSLog("Vision Browser · veille : \(sleepers.count) onglet(s) endormi(s), \(awake) éveillé(s) sur \(allTabs.count)")
        }
        // Le dernier onglet actif de chaque espace reste : revenir dans un espace ne doit pas le trouver vide.
        let kept = Set(activeBySpace.values.map(\.id))
        let toArchive = TabOrganizer.archiveCandidates(infos, activeID: displayedTab?.id, now: now).filter { !kept.contains($0) }
        for id in toArchive {
            guard let tab = tab(id), let url = tab.url else { continue }
            close(tab, rememberForReopen: false)
            archived.insert(ArchivedTab(id: tab.id, url: url, title: tab.title, spaceID: tab.space.id, archivedAt: now), at: 0)
        }
        if !toArchive.isEmpty {
            archived = Array(archived.prefix(ArchivedTab.limit))
            if !overview.isHidden { overview.reload() }
            scheduleSessionSave()
        }
    }

    private func info(_ tab: BrowserTab) -> TabInfo {
        TabInfo(id: tab.id, url: tab.url, title: tab.title, isPinned: tab.isPinned, isAwake: !tab.isAsleep, lastActivated: tab.lastActivated)
    }

    private func card(_ tab: BrowserTab) -> TabCard {
        let host = DomainPolicy.displayHost(for: tab.url) ?? ""
        let away = tab.homeURL.map { home in tab.url.map { PlacesStore.key($0) != PlacesStore.key(home) } ?? false } ?? false
        return TabCard(id: tab.id, title: tab.title?.isEmpty == false ? tab.title! : (host.isEmpty ? "Nouvel onglet" : host),
                       host: host, url: tab.url, image: tab.snapshot, spaceColor: tab.space.color, isPinned: tab.isPinned,
                       isActive: activeBySpace[tab.space.id] === tab, canGoHome: tab.isPinned && away)
    }

    private func card(_ entry: ArchivedTab) -> TabCard {
        let host = DomainPolicy.displayHost(for: entry.url) ?? ""
        return TabCard(id: entry.id, title: entry.title?.isEmpty == false ? entry.title! : host, host: host, url: entry.url,
                       image: SnapshotStore.shared.image(for: entry.id), spaceColor: space(entry.spaceID)?.color ?? .gray,
                       isArchived: true)
    }

    // MARK: Ctrl+Tab (ordre d'utilisation récente)

    /// Renvoie vrai si l'événement est consommé.
    private func handleSwitcherEvent(_ event: NSEvent) -> Bool {
        // Cmd+C / Cmd+X (pages, barre Cmd+T, champs de l'app) : le presse-papier sera relu juste après.
        if event.type == .keyDown, event.modifierFlags.contains(.command),
           let key = event.charactersIgnoringModifiers?.lowercased(), key == "c" || key == "x" {
            ClipboardMonitor.shared.checkSoon(source: DomainPolicy.displayHost(for: displayedTab?.url) ?? "Vision Browser")
            return false
        }
        if event.type == .flagsChanged {
            if !switcherTabs.isEmpty && !event.modifierFlags.contains(.control) { commitSwitcher() }
            return false
        }
        if !switcherTabs.isEmpty && event.keyCode == 53 { cancelSwitcher(); return true }
        guard event.keyCode == 48, event.modifierFlags.contains(.control) else { return false }
        guard overview.isHidden, commandBar.isHidden else { return true }
        let step = event.modifierFlags.contains(.shift) ? -1 : 1
        if switcherTabs.isEmpty {
            let order = TabOrganizer.recentFirst(tabs.map(info)).compactMap { info in tabs.first { $0.id == info.id } }
            guard order.count > 1 else { return true }
            switcherTabs = order
            switcherIndex = step > 0 ? 1 : order.count - 1
            hideShelf()
            // Un appui bref bascule sans afficher le sélecteur (pas de clignotement).
            switcherShowTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(180))
                guard !Task.isCancelled else { return }
                self?.presentSwitcher()
            }
        } else {
            switcherIndex = (switcherIndex + step + switcherTabs.count) % switcherTabs.count
            if switcher.isHidden { presentSwitcher() } else { switcher.select(switcherIndex) }
        }
        return true
    }

    private func presentSwitcher() {
        switcherShowTask?.cancel()
        guard !switcherTabs.isEmpty else { return }
        Task { [weak self] in
            await self?.displayedTab?.captureSnapshot(timeout: .milliseconds(250))
            guard let self, !self.switcherTabs.isEmpty else { return }
            self.switcher.show(cards: self.switcherTabs.map(self.card), selected: self.switcherIndex)
            let size = self.switcher.preferredSize(maxWidth: (self.window?.contentView?.bounds.width ?? 800) - 80)
            self.switcherWidth?.constant = size.width
            self.switcherHeight?.constant = size.height
        }
    }

    private func commitSwitcher() {
        let target = switcherTabs.indices.contains(switcherIndex) ? switcherTabs[switcherIndex] : nil
        cancelSwitcher()
        if let target { select(target) }
    }

    private func cancelSwitcher() {
        switcherShowTask?.cancel()
        switcherTabs = []
        switcher.isHidden = true
    }

    // MARK: Étagère du bas

    private func configureShelf() {
        shelf.isHidden = true
        shelf.alphaValue = 0
        bottomZone.onEnter = { [weak self] in
            self?.shelfTask?.cancel()
            // Courte attente : un passage rapide de la souris (vers le Dock) ne fait pas monter l'étagère.
            self?.shelfTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(120))
                guard !Task.isCancelled else { return }
                self?.showShelf()
            }
        }
        bottomZone.onExit = { [weak self] in
            if self?.shelf.isHidden ?? true { self?.shelfTask?.cancel() }
        }
        shelf.onMouseExit = { [weak self] in
            self?.shelfTask?.cancel()
            self?.shelfTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled, let self, let window = self.window else { return }
                let point = self.shelf.convert(window.mouseLocationOutsideOfEventStream, from: nil)
                if !self.shelf.bounds.contains(point) { self.hideShelf() }
            }
        }
        shelf.onSelectTab = { [weak self] id in
            guard let self, let tab = self.tab(id) else { return }
            self.hideShelf()
            self.select(tab)
        }
        shelf.onHome = { [weak self] id in
            guard let self, let tab = self.tab(id) else { return }
            self.goHome(tab)
            self.hideShelf()
            self.select(tab)
        }
        shelf.onSelectSpace = { [weak self] id in
            guard let self, let space = self.space(id) else { return }
            self.switchTo(space)
            self.refreshShelf()
        }
        shelf.onShowAll = { [weak self] in self?.showOverview() }
    }

    private func showShelf() {
        guard shelf.isHidden, overview.isHidden, commandBar.isHidden, switcherTabs.isEmpty, window?.isKeyWindow == true else { return }
        Task { [weak self] in
            await self?.displayedTab?.captureSnapshot(timeout: .milliseconds(250))
            guard let self, self.overview.isHidden, self.commandBar.isHidden else { return }
            self.refreshShelf()
            self.shelf.isHidden = false
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.15
                MainActor.assumeIsolated { self.shelf.animator().alphaValue = 1 }
            }, completionHandler: nil)
        }
    }

    private func refreshShelf() {
        let content = TabOrganizer.shelf(tabs.map(info))
        let byID = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0) })
        shelf.update(spaces: spaces.map { .init(id: $0.id, name: $0.name, color: $0.color, count: tabsBySpace[$0.id]?.count ?? 0,
                                                isCurrent: $0 === currentSpace) },
                     pinned: content.pinned.compactMap { byID[$0.id] }.map(card),
                     recent: content.recent.compactMap { byID[$0.id] }.map(card))
    }

    private func hideShelf() {
        shelfTask?.cancel()
        guard !shelf.isHidden else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            MainActor.assumeIsolated { self.shelf.animator().alphaValue = 0 }
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated { if self?.shelf.alphaValue == 0 { self?.shelf.isHidden = true } }
        })
    }

    // MARK: Vue d'ensemble

    private func configureOverview() {
        overview.contentProvider = { [weak self] spaceID in self?.overviewContent(for: spaceID) ?? OverviewContent() }
        overview.onOpenTab = { [weak self] id in
            guard let self, let tab = self.tab(id) else { return }
            self.select(tab)
            self.closeOverview(expanding: id)
        }
        overview.onCloseTab = { [weak self] id in
            guard let self, let tab = self.tab(id) else { return }
            self.close(tab)
            self.overview.reload()
        }
        overview.onHome = { [weak self] id in
            guard let self, let tab = self.tab(id) else { return }
            self.goHome(tab)
            self.select(tab)
            self.closeOverview(expanding: id)
        }
        overview.onReopenArchived = { [weak self] id in
            guard let self else { return }
            self.reopenArchived(id)
            self.closeOverview(expanding: id)
        }
        overview.onOpenFavorite = { [weak self] url, spaceID in
            guard let self else { return }
            self.newTab(url: url, in: self.space(spaceID) ?? self.currentSpace, activate: true)
            self.closeOverview(expanding: nil)
        }
        overview.onPin = { [weak self] id, pinned in
            guard let self, let tab = self.tab(id) else { return }
            self.setPinned(tab, pinned)
            self.overview.reload()
        }
        overview.onMove = { [weak self] id, spaceID in
            guard let self, let tab = self.tab(id), let target = self.space(spaceID), tab.space !== target else { return }
            let shown = self.overview.shownSpaceID
            self.move(tab, to: target)
            if let shown { self.overview.show(space: shown) }
            self.overview.reload()
        }
        overview.onDismiss = { [weak self] in self?.closeOverview(expanding: self?.activeTab?.id) }
    }

    private func overviewContent(for spaceID: UUID) -> OverviewContent {
        let list = tabsBySpace[spaceID] ?? []
        let byID = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
        let groups: [OverviewContent.Group] = TabOrganizer.groups(list.filter { !$0.isPinned }.map(info)).map { group in
            switch group {
            case .single(let info): .single(card(byID[info.id]!))
            case .stack(let site, let infos): .stack(site: site, cards: infos.compactMap { byID[$0.id] }.map(card))
            }
        }
        return OverviewContent(
            pinned: list.filter(\.isPinned).map(card),
            groups: groups,
            archived: archived.filter { $0.spaceID == spaceID }.map(card),
            favorites: (places?.favorites(limit: 60) ?? []).map { .init(title: $0.title ?? PlacesStore.host($0.url), url: $0.url) })
    }

    func showOverview() {
        guard overview.isHidden, !overviewOpening else { return }
        overviewOpening = true
        hideShelf()
        cancelSwitcher()
        if !commandBar.isHidden { hideCommandBar() }
        Task { [weak self] in
            await self?.displayedTab?.captureSnapshot(timeout: .milliseconds(250))
            guard let self else { return }
            self.overviewOpening = false
            self.overview.present(spaces: self.spaces.map { .init(id: $0.id, name: $0.name, color: $0.color) },
                                  showing: self.currentSpace.id, activeTabID: self.activeTab?.id,
                                  pageImage: self.displayedTab?.snapshot)
        }
    }

    private func closeOverview(expanding id: UUID?) {
        guard !overview.isHidden else { return }
        overview.dismiss(expanding: id) { [weak self] in
            guard let self else { return }
            if let view = self.displayedTab?.liveWebView { self.window?.makeFirstResponder(view) }
            else { self.showCommandBar(newTab: true) }
        }
    }

    /// Pincer pour dézoomer sur une page à taille réelle ouvre la vue d'ensemble (comme Safari).
    private func handlePagePinch(_ event: NSEvent) -> Bool {
        guard overview.isHidden, let view = displayedTab?.liveWebView, view.magnification <= 1.001 else { return false }
        let point = view.convert(event.locationInWindow, from: nil)
        guard view.bounds.contains(point) else { return false }
        if event.phase == .began { pinchAccumulator = 0 }
        guard event.magnification < 0 || pinchAccumulator < 0 else { return false }
        pinchAccumulator += event.magnification
        if pinchAccumulator < -0.1 {
            pinchAccumulator = 0
            showOverview()
        }
        if event.phase == .ended || event.phase == .cancelled { pinchAccumulator = 0 }
        return true
    }

    // MARK: Barre de commande (Cmd+T / Cmd+L)

    private func showCommandBar(newTab: Bool) {
        hideShelf()
        if !overview.isHidden { overview.isHidden = true }
        // L'état de la CLI a pu changer (bw login fait dans le Terminal) : vérifié en arrière-plan.
        if !BitwardenService.shared.isUnlocked { Task { await BitwardenService.shared.refreshStatus() } }
        commandBar.present(text: newTab ? "" : (activeTab?.url?.absoluteString ?? ""), newTab: newTab)
        window?.makeFirstResponder(commandBar.field)
        refreshResults(for: commandBar.query)
    }

    private func hideCommandBar() {
        suggestionTask?.cancel()
        commandBar.isHidden = true
        if let webView = displayedTab?.liveWebView { window?.makeFirstResponder(webView) }
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
                     routedSpaceForActiveHost: url.flatMap { config.spaceID(for: $0) },
                     bitwarden: BitwardenService.shared.status,
                     bitwardenBusy: BitwardenService.shared.isBusy)
    }

    /// Résultats locaux immédiatement, puis suggestions du moteur de recherche dès qu'elles arrivent.
    private func refreshResults(for query: String, keepSelection: Bool = false) {
        commandBar.show(results: localResults(for: query), keepSelection: keepSelection)
        suggestionTask?.cancel()
        guard case .search? = AddressInput.parse(query) else { return }
        suggestionTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            let suggestions = await SearchSuggestions.fetch(query)
            guard !Task.isCancelled, let self, !self.commandBar.isHidden, self.commandBar.query == query else { return }
            self.commandBar.show(results: self.localResults(for: query, suggestions: suggestions), keepSelection: true)
        }
    }

    private func localResults(for query: String, suggestions: [String] = []) -> [CommandResult] {
        let bitwarden = BitwardenService.shared
        let entries = bitwarden.isUnlocked ? bitwarden.vault.search(query, config: config, currentSpaceID: currentSpace.id) : []
        return engine.results(for: query, tabs: openTabInfos, context: commandContext, suggestions: suggestions,
                              archived: archived, clipboard: ClipboardMonitor.shared.history, bitwarden: entries)
    }

    /// Presse-papier : Entrée ouvre un lien ou colle dans le champ actif de la page ;
    /// Cmd+Entrée remet l'élément dans le presse-papier. Touch ID d'abord pour un secret.
    private func useClipboardItem(_ id: UUID, copyOnly: Bool) {
        guard let item = ClipboardMonitor.shared.history.items.first(where: { $0.id == id }) else { return }
        if item.kind == .link, !copyOnly, let url = item.url {
            newTab(url: url, activate: true)
            return
        }
        Task { [weak self] in
            if item.kind == .secret {
                let reason = copyOnly ? "copier le mot de passe gardé dans l'historique" : "coller le mot de passe gardé dans l'historique"
                guard await ClipboardMonitor.authenticate(reason: reason) else { return }
            }
            guard let self else { return }
            if copyOnly {
                ClipboardMonitor.shared.write(item)
                self.domainToast.show(text: item.kind == .secret ? "Copié (masqué)" : "Copié", symbol: "doc.on.clipboard.fill", tint: .systemPurple)
            } else {
                if let view = self.displayedTab?.liveWebView { self.window?.makeFirstResponder(view) }
                ClipboardMonitor.shared.paste(item)
            }
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
            if let tab = tab(id) { select(tab) }
        case .archived(let id, _):
            reopenArchived(id)
        case .clipboard(let id, _, _):
            useClipboardItem(id, copyOnly: invert)
        case .bitwarden(let id, _):
            useBitwardenItem(id, copyOnly: invert)
        case .command(.unlockBitwarden):
            unlockBitwardenAction(nil)
        case .command(.lockBitwarden):
            BitwardenService.shared.lock()
            domainToast.show(text: "Bitwarden verrouillé", symbol: "lock.fill", tint: .systemBlue)
        case .command(.setupBitwarden):
            showBitwardenSetup()
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

    // MARK: Bitwarden (CLI)

    /// Entrée : ouvre le site dans l'espace de l'identifiant et le remplit. Cmd+Entrée : copie le mot de passe
    /// (masqué dans l'historique, effacé du presse-papier après 90 s). Touch ID d'abord.
    private func useBitwardenItem(_ id: String, copyOnly: Bool) {
        let service = BitwardenService.shared
        guard let item = service.vault.items.first(where: { $0.id == id }) else { return }
        Task { [weak self] in
            let reason = copyOnly ? "copier le mot de passe « \(item.name) »" : "remplir l'identifiant « \(item.name) »"
            guard await service.authenticate(reason: reason) else { return }
            let credentials: (username: String?, password: String?)
            do { credentials = try await service.credentials(for: id) } catch {
                self?.showError("Bitwarden", error)
                return
            }
            guard let self else { return }
            if copyOnly {
                guard let password = credentials.password else { return }
                let clip = ClipboardItem(kind: .secret, text: password, source: "Bitwarden", copiedAt: Date(), fromBitwarden: true)
                ClipboardMonitor.shared.write(clip)
                ClipboardMonitor.shared.record(clip)
                ClipboardMonitor.shared.clearLater(after: .seconds(90))
                self.domainToast.show(text: "Mot de passe copié (effacé dans 90 s)", symbol: "key.fill", tint: .systemBlue)
                return
            }
            guard let url = item.loginURL else {
                return self.domainToast.show(text: "Pas d'adresse web pour « \(item.name) »", symbol: "exclamationmark.triangle.fill", tint: .systemOrange)
            }
            let space = service.vault.spaceID(for: item, config: self.config).flatMap(self.space) ?? self.currentSpace
            let tab = self.newTab(url: url, in: space, activate: true)
            self.pendingFills[tab.id] = PendingFill(item: item, username: credentials.username, password: credentials.password,
                                                    expires: Date().addingTimeInterval(180))
        }
    }

    /// Remplit l'onglet si la page est bien sur le site enregistré (garde-fou anti-hameçonnage).
    private func runFill(_ fill: PendingFill, in tab: BrowserTab) {
        guard let view = tab.liveWebView, BitwardenVault.pageMatches(tab.url, item: fill.item) else { return }
        let arguments: [String: Any] = ["username": fill.username ?? "", "password": fill.password ?? "",
                                        "site": tab.url?.host()?.lowercased() ?? ""]
        Task { [weak self] in
            let result = try? await view.callAsyncJavaScript(LoginFiller.script, arguments: arguments, contentWorld: EscapeRelay.world)
            guard let self, (result as? String) == "filled" else { return }
            self.pendingFills[tab.id] = nil
            self.domainToast.show(text: "Rempli : \(fill.username ?? fill.item.name)", symbol: "checkmark.shield.fill", tint: .systemBlue,
                                  space: (tab.space.name, tab.space.color))
        }
    }

    @objc func unlockBitwardenAction(_ sender: Any?) {
        let service = BitwardenService.shared
        if service.isDemo || service.isUnlocked { return }
        if service.isBusy {
            return domainToast.show(text: "Bitwarden se déverrouille… (quelques secondes)", symbol: "hourglass", tint: .systemBlue)
        }
        guard case .locked(let email) = service.status else { return showBitwardenSetup() }
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Déverrouiller Bitwarden"
        alert.informativeText = "Pour chercher dans ton coffre depuis Cmd+T\(email.map { " (\($0))" } ?? ""). "
            + "Le mot de passe maître est transmis à la CLI officielle bw, jamais enregistré."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "Mot de passe maître"
        alert.accessoryView = field
        alert.addButton(withTitle: "Déverrouiller")
        alert.addButton(withTitle: "Annuler")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            let password = field.stringValue
            field.stringValue = ""
            // Reste affiché jusqu'au résultat : la CLI met une dizaine de secondes à dériver la clé du coffre.
            self?.domainToast.show(text: "Déverrouillage de Bitwarden… (environ 10 s)", symbol: "hourglass", tint: .systemBlue,
                                   duration: .seconds(60))
            Task { [weak self] in
                do {
                    try await service.unlock(password: password)
                    self?.domainToast.show(text: "Bitwarden déverrouillé · \(service.vault.items.count) identifiants",
                                           symbol: "lock.open.fill", tint: .systemBlue)
                } catch {
                    self?.domainToast.show(text: "Bitwarden toujours verrouillé", symbol: "lock.fill", tint: .systemRed)
                    self?.showError("Bitwarden n'a pas pu être déverrouillé", error)
                }
            }
        }
    }

    private func showBitwardenSetup() {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Connecter la CLI Bitwarden"
        alert.informativeText = BitwardenService.shared.status == .notInstalled
            ? "La CLI officielle bw est introuvable. Installe-la avec : brew install bitwarden-cli"
            : "Une seule fois, dans le Terminal : « bw login » (e-mail, mot de passe maître, double authentification). "
              + "Si ton compte est sur le serveur européen, tape d'abord « bw config server https://vault.bitwarden.eu »."
        alert.addButton(withTitle: "Copier « bw login »")
        alert.addButton(withTitle: "Fermer")
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("bw login", forType: .string)
        }
    }

    private func showError(_ title: String, _ error: Error) {
        guard let window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.beginSheetModal(for: window)
    }

    @objc func linkBitwardenFolderAction(_ sender: Any?) {
        let folderID = (sender as? NSMenuItem)?.representedObject as? String
        config.linkBitwardenFolder(folderID, to: currentSpace.id)
        spacesStore.save(config)
        onSpacesChanged?()
        let name = folderID.flatMap { id in BitwardenService.shared.vault.folders.first { $0.id == id }?.name }
        announceSpace(name.map { "Dossier Bitwarden « \($0) » relié à" } ?? "Dossier Bitwarden automatique pour", symbol: "shield.lefthalf.filled")
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

    /// Dans la vue d'ensemble, ⌘D et ⌘W visent la carte choisie ; ailleurs, l'onglet affiché.
    private var targetTab: BrowserTab? { overview.focusedTabID.flatMap(tab) ?? activeTab }

    @objc func newTabAction(_ sender: Any?) { showCommandBar(newTab: true) }
    @objc func editAddressAction(_ sender: Any?) { showCommandBar(newTab: false) }
    @objc func toggleFavoriteAction(_ sender: Any?) { toggleFavoriteForActiveTab() }
    @objc func togglePinAction(_ sender: Any?) {
        guard let tab = targetTab else { return }
        setPinned(tab, !tab.isPinned)
        overview.reload()
    }
    @objc func showOverviewAction(_ sender: Any?) {
        overview.isHidden ? showOverview() : closeOverview(expanding: activeTab?.id)
    }
    @objc func closeTabAction(_ sender: Any?) {
        if !commandBar.isHidden { return hideCommandBar() }
        if !overview.isHidden {
            if let tab = targetTab { close(tab); overview.reload() }
            return
        }
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
        if !overview.isHidden { overview.show(space: spaces[n - 1].id) }
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
        case #selector(deleteSpaceAction(_:)): return spaces.count > 1
        case #selector(moveTabToSpaceAction(_:)): return activeTab?.url != nil
        case #selector(routeHostHereAction(_:)):
            return activeTab?.url.map { config.spaceID(for: $0) != currentSpace.id && $0.host() != nil } ?? false
        case #selector(switchSpaceByNumberAction(_:)): return spaces.indices.contains(item.tag - 1)
        case #selector(togglePinAction(_:)):
            item.title = targetTab?.isPinned == true ? "Désépingler l'onglet" : "Épingler l'onglet"
            return targetTab != nil
        default: return true
        }
    }

    // MARK: NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) { host.controller.didFocusWindow(self) }
    func windowDidResignKey(_ notification: Notification) {
        cancelSwitcher()
        hideShelf()
    }

    func windowWillClose(_ notification: Notification) {
        saveSessionNow()
        maintenanceTask?.cancel()
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
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

private extension NSLayoutConstraint {
    func withPriority(_ priority: NSLayoutConstraint.Priority) -> NSLayoutConstraint {
        self.priority = priority
        return self
    }
}
