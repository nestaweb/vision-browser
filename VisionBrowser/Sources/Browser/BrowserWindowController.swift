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

    private let pageContainer = PageContainerView()
    /// Voile posé sur la page quand la barre Cmd+T est ouverte ; un clic dessus referme la barre.
    private let veil = VeilView()
    private let commandBar = CommandBarView()
    private let domainToast = DomainToastView()
    private let insecureStripe = PassthroughView()
    /// Indicateur de chargement de la page affichée (le trait, au bord haut).
    private let loadingLine = LoadingLineView()
    private let trafficLightZone = TrafficLightZone()
    private let bottomZone = BottomEdgeZone()
    /// Vue d'ensemble « Scène » (D3) : la page recule, rangée des onglets dessous, rail des espaces à gauche.
    private let overview = SceneView()
    /// Page affichée à l'ouverture de la Scène : Échap y ramène, même après avoir changé d'espace.
    private var sceneOrigin: (space: Space, tab: BrowserTab?)?
    private let switcher = TabSwitcherView()
    private var switcherWidth: NSLayoutConstraint?
    /// Distance de l'étiquette du haut au bord : agrandie en plein écran pour passer sous l'encoche.
    private var toastTop: NSLayoutConstraint?
    private var switcherHeight: NSLayoutConstraint?
    /// Point d'ancrage du popup Bitwarden (coin supérieur droit).
    let popupAnchor = PassthroughView()

    private var saveTask: Task<Void, Never>?
    private var maintenanceTask: Task<Void, Never>?
    /// Attente sur le bord bas avant d'ouvrir la Scène (un passage vers le Dock ne l'ouvre pas).
    private var bottomEdgeTask: Task<Void, Never>?
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
    /// Sens demandé par ⇧← / ⇧→ (qui bouclent), pour que la page glisse dans le bon sens au passage du dernier au premier.
    private var spaceStepHint: Int?
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
        let window = BrowserWindow(contentRect: NSRect(x: 0, y: 0, width: 1360, height: 880),
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
        window.onEscape = { [weak self] in self?.handleEscape() }
        pageContainer.onEscape = { [weak self] in self?.handleEscape() }
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
            if self.commandBar.isOpen { self.refreshResults(for: self.commandBar.query, keepSelection: true) }
        }
        ClipboardMonitor.shared.onChange = { [weak self] in
            guard let self, self.commandBar.isOpen else { return }
            self.refreshResults(for: self.commandBar.query, keepSelection: true)
        }
        host.controller.didOpenWindow(self)
        host.controller.didFocusWindow(self)
        installEventMonitors()
        startMaintenance()
    }

    required init?(coder: NSCoder) { fatalError("non utilisé") }

    /// Moniteurs locaux : ils voient les événements avant la fenêtre et les menus.
    /// - Chiffres (⌘1…9, ⌘0, ⌃1…9) : reconnus par touche physique, voir `handleDigitShortcut`.
    /// - Ctrl+Tab : macOS traite Tab (navigation au clavier) avant tout raccourci de menu.
    /// - Relâcher Ctrl valide le sélecteur.
    /// - Pincer pour dézoomer sur une page à 100 % ouvre la vue d'ensemble.
    private func installEventMonitors() {
        let keys = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            let consumed = MainActor.assumeIsolated { self.handleKeyEvent(event) }
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

        // L'étiquette du haut passe au-dessus du voile de la barre Cmd+T (sinon elle paraît grisée).
        for view in [pageContainer, loadingLine, dragStrip, insecureStripe, bottomZone, overview, switcher, veil, domainToast, commandBar,
                     trafficLightZone, popupAnchor] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        toastTop = domainToast.topAnchor.constraint(equalTo: content.topAnchor, constant: 12)
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

            loadingLine.topAnchor.constraint(equalTo: content.topAnchor),
            loadingLine.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            loadingLine.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            loadingLine.heightAnchor.constraint(equalToConstant: LoadingLineView.height),

            insecureStripe.topAnchor.constraint(equalTo: content.topAnchor),
            insecureStripe.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            insecureStripe.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            insecureStripe.heightAnchor.constraint(equalToConstant: 3),

            bottomZone.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            bottomZone.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bottomZone.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bottomZone.heightAnchor.constraint(equalToConstant: 4),


            overview.topAnchor.constraint(equalTo: content.topAnchor),
            overview.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            overview.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            overview.trailingAnchor.constraint(equalTo: content.trailingAnchor),

            switcher.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            switcher.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            switcherWidth, switcherHeight,

            toastTop!,
            domainToast.centerXAnchor.constraint(equalTo: content.centerXAnchor),

            // Au quart de la hauteur : la liste a la place de se dérouler dessous.
            NSLayoutConstraint(item: commandBar, attribute: .top, relatedBy: .equal, toItem: content, attribute: .bottom, multiplier: 0.24, constant: 0),
            commandBar.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            veil.topAnchor.constraint(equalTo: content.topAnchor),
            veil.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            veil.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            veil.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            // La proportion est une simple préférence, sous la priorité de taille de la fenêtre (500).
            // Plus forte, elle bornait la fenêtre à 1200 pt (0,5 × largeur + 160 ≤ 760) : AppKit en déduit
            // `maxFullScreenContentSize`, d'où des bandes noires en plein écran.
            commandBar.widthAnchor.constraint(equalTo: content.widthAnchor, multiplier: 0.5, constant: 160)
                .withPriority(NSLayoutConstraint.Priority(480)),
            commandBar.widthAnchor.constraint(lessThanOrEqualToConstant: 640),

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

        commandBar.onQueryChange = { [weak self] query in self?.refreshResults(for: query) }
        commandBar.onExecute = { [weak self] result, typed, mode in self?.execute(result, typed: typed, mode: mode) }
        commandBar.onCancel = { [weak self] in self?.hideCommandBar() }
        veil.onClick = { [weak self] in self?.hideCommandBar() }
        commandBar.onStepSpace = { [weak self] step in
            // La barre se referme ; elle se rouvre d'elle-même si l'espace d'arrivée est vide.
            self?.hideCommandBar()
            self?.stepSpace(by: step)
        }

        configureBottomEdge()
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
        let from = currentSpace
        currentSpace = space
        if let tab = activeBySpace[space.id] ?? tabsBySpace[space.id]?.last {
            display(tab, announce: announce, from: from)
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

    func renameCurrentSpace(to name: String) { renameSpace(currentSpace.id, to: name) }

    /// Renomme un espace (nom rendu unique par la configuration) ; menus, titre et Scène suivent.
    func renameSpace(_ id: UUID, to name: String) {
        guard let space = space(id) else { return }
        config.rename(id, to: name)
        space.name = config.space(id)?.name ?? space.name
        spacesStore.save(config)
        updateWindowTitle()
        onSpacesChanged?()
        overview.renameSpace(id, to: space.name)
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
        tab.opener = opener
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
    /// - Parameter fromSpace: l'espace affiché juste avant (changement d'espace), pour le sens de la transition.
    private func display(_ tab: BrowserTab, announce: Bool, from fromSpace: Space? = nil) {
        activeBySpace[tab.space.id] = tab
        tab.lastActivated = Date()
        if tab === displayedTab, let view = tab.liveWebView, view.superview === pageContainer, !view.isHidden {
            return updateChrome(announce: false)
        }
        let previous = displayedTab
        let transition = pageTransition(from: previous, fromSpace: fromSpace, to: tab)
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
        let animated = animatePage(view, replacing: previous?.liveWebView, transition)
        // L'ancienne page reste visible sous la nouvelle tant que celle-ci apparaît (sinon le fond de la fenêtre clignote).
        hidePages(except: view, after: animated)
        if !commandBar.isOpen && overview.isHidden { window?.makeFirstResponder(view) }
        host.controller.didActivateTab(tab, previousActiveTab: previous)
        updateChrome(announce: announce)
        // Autre page à l'écran : le trait repart de son état à elle.
        loadingLine.update(loading: view.isLoading, progress: view.estimatedProgress, color: tab.space.color, reset: true)
    }

    /// Masque les pages autres que `kept`, après les avoir capturées (et après `delay`, durée de la transition).
    private func hidePages(except kept: NSView?, after delay: TimeInterval = 0) {
        for other in pageContainer.subviews where other !== kept && !other.isHidden {
            let owner = allTabs.first { $0.liveWebView === other }
            Task { [weak self] in
                await owner?.captureSnapshot(timeout: .milliseconds(400))
                if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
                guard let self, other !== self.displayedTab?.liveWebView else { return }
                other.isHidden = true
            }
        }
    }

    /// Quel mouvement pour passer de la page affichée à `tab` (voir `PageTransition`).
    private func pageTransition(from previous: BrowserTab?, fromSpace: Space?, to tab: BrowserTab) -> PageTransition {
        guard let origin = fromSpace ?? previous?.space,
              let fromIndex = spaces.firstIndex(where: { $0 === origin }),
              let toIndex = spaces.firstIndex(where: { $0 === tab.space }) else { return .none }
        let list = tabsBySpace[tab.space.id] ?? []
        let fromTab = origin === tab.space ? previous.flatMap { old in list.firstIndex { $0 === old } } : nil
        return PageTransition.between(fromSpace: fromIndex, toSpace: toIndex, fromTab: fromTab,
                                      toTab: list.firstIndex { $0 === tab } ?? 0, spaceStep: spaceStepHint)
    }

    /// Fait entrer la nouvelle page (glissement court + fondu) ; au changement d'espace, l'ancienne recule d'un demi-pas, sans s'estomper.
    /// Avec « Réduire les animations », fondu seul. Renvoie la durée, 0 si rien n'est animé.
    private func animatePage(_ view: NSView, replacing old: NSView?, _ transition: PageTransition) -> TimeInterval {
        guard transition != .none, overview.isHidden, window?.isVisible == true, let layer = view.layer else { return 0 }
        pageContainer.layoutSubtreeIfNeeded()
        let move = Design.Motion.allowsMovement()
        let duration: TimeInterval
        if case .space = transition { duration = Design.Motion.duration(.slow) } else { duration = Design.Motion.duration(.medium) }
        let entry = move ? transition.entryOffset : (0, 0)
        layer.add(Self.pageAnimation(from: entry, to: (0, 0), opacity: (0, 1), duration: duration), forKey: "vision.page")
        if move, let exit = transition.exitOffset, let old, old !== view, let oldLayer = old.layer {
            // L'ancienne page reste opaque (sinon l'écran s'assombrit à mi-course) : elle recule, la nouvelle la recouvre.
            oldLayer.add(Self.pageAnimation(from: (0, 0), to: exit, opacity: (1, 1), duration: duration), forKey: "vision.page")
        }
        return duration
    }

    /// Glissement et fondu d'un calque. Les décalages sont donnés à l'écran (y vers le bas) ; le conteneur des pages
    /// n'est pas retourné, son repère a y vers le haut, d'où le signe inversé.
    private static func pageAnimation(from: (x: CGFloat, y: CGFloat), to: (x: CGFloat, y: CGFloat),
                                      opacity: (CGFloat, CGFloat), duration: TimeInterval) -> CAAnimation {
        let move = CABasicAnimation(keyPath: "transform")
        move.fromValue = CATransform3DMakeTranslation(from.x, -from.y, 0)
        move.toValue = CATransform3DMakeTranslation(to.x, -to.y, 0)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = opacity.0
        fade.toValue = opacity.1
        let group = CAAnimationGroup()
        group.animations = [move, fade]
        group.duration = duration
        group.timingFunction = Design.Motion.curve
        return group
    }

    private func retireDisplayedPage() {
        displayedTab = nil
        hidePages(except: nil)
        loadingLine.update(loading: false, progress: 0, color: .clear, reset: true)
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
        // Remplissage en attente : on n'attend pas la fin du chargement de la nouvelle page.
        resumeFill(in: tab)
        if let url = tab.url { places?.recordVisit(url: url, title: tab.title) }
        if tab === activeTab { updateChrome(announce: DomainPolicy.shouldAnnounce(previous: tab.previousURL, next: tab.url)) }
        scheduleSessionSave()
    }

    func tabDidChangeTitle(_ tab: BrowserTab) {
        if let url = tab.url, let title = tab.title { places?.updateTitle(url: url, title: title) }
        if tab === activeTab { updateWindowTitle() }
    }

    /// Page chargée : sa carte est rafraîchie peu après (le temps que la page se dessine).
    /// Chargement commencé, avancé ou fini : le trait du haut suit la page affichée.
    func tabLoadingDidChange(_ tab: BrowserTab) {
        guard tab === displayedTab, let view = tab.liveWebView else { return }
        loadingLine.update(loading: view.isLoading, progress: view.estimatedProgress, color: tab.space.color)
    }

    func tabDidFinishLoading(_ tab: BrowserTab) {
        resumeFill(in: tab)
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

    /// Touches de la rangée des chiffres, par position physique (identique sur QWERTY et AZERTY).
    private static let digitRow: [UInt16: Int] = [18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9, 29: 0]

    /// ⌘1…9 (onglet), ⌘0 (taille réelle), ⌃1…9 (espace), quelle que soit la disposition du clavier.
    ///
    /// Sur un clavier français, les chiffres demandent Maj : ⌘& n'est pas « ⌘1 » pour le menu. Comme Safari et
    /// Chrome, on regarde donc la touche physique plutôt que le caractère produit.
    private func handleDigitShortcut(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, let digit = Self.digitRow[event.keyCode] else { return false }
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if flags == .command {
            if digit == 0 { zoomResetAction(nil) } else { selectTab(number: digit) }
            return true
        }
        if flags == .control, digit > 0 {
            switchSpace(number: digit)
            return true
        }
        return false
    }

    /// Renvoie vrai si l'événement est consommé.
    private func handleKeyEvent(_ event: NSEvent) -> Bool {
        if handleDigitShortcut(event) { return true }
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
        guard overview.isHidden, !commandBar.isOpen else { return true }
        let step = event.modifierFlags.contains(.shift) ? -1 : 1
        if switcherTabs.isEmpty {
            let order = TabOrganizer.recentFirst(tabs.map(info)).compactMap { info in tabs.first { $0.id == info.id } }
            guard order.count > 1 else { return true }
            switcherTabs = order
            switcherIndex = step > 0 ? 1 : order.count - 1
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

    // MARK: Échap

    /// Échap, quand ni la page ni un champ ne s'en est servi : ferme la surcouche ouverte, sinon ouvre la vue
    /// d'ensemble, sauf si la page était occupée (champ en saisie, dialogue). Jamais de bip, jamais de sortie du plein écran.
    private func handleEscape() {
        if commandBar.isOpen { return hideCommandBar() }
        // Même effet que dans la Scène : effacer le filtre, sinon revenir à la page d'avant.
        if !overview.isHidden { return overview.handleEscape() }
        guard let view = displayedTab?.liveWebView else { return showOverview() }
        Task { [weak self] in
            guard await !EscapeRelay.shared.pageIsBusy(view), let self, view === self.displayedTab?.liveWebView else { return }
            self.showOverview()
        }
    }

    // MARK: Étagère du bas

    /// La souris posée contre le bord bas ouvre la Scène (D6 : remplace l'étagère, qui faisait doublon avec la rangée).
    private func configureBottomEdge() {
        bottomZone.onEnter = { [weak self] in
            self?.bottomEdgeTask?.cancel()
            self?.bottomEdgeTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled, let self, self.overview.isHidden, !self.commandBar.isOpen,
                      self.switcherTabs.isEmpty, self.window?.isKeyWindow == true else { return }
                self.showOverview()
            }
        }
        bottomZone.onExit = { [weak self] in self?.bottomEdgeTask?.cancel() }
    }

    // MARK: Vue d'ensemble

    private func configureOverview() {
        overview.contentProvider = { [weak self] spaceID in self?.sceneContent(for: spaceID) ?? SceneContent() }
        overview.onOpenTab = { [weak self] id in
            guard let self, let tab = self.tab(id) else { return }
            self.select(tab)
            self.closeOverview(expanding: id)
        }
        overview.onReopenArchived = { [weak self] id in
            guard let self else { return }
            self.reopenArchived(id)
            self.closeOverview(expanding: id)
        }
        overview.onMove = { [weak self] id, spaceID in
            guard let self, let tab = self.tab(id), let target = self.space(spaceID), tab.space !== target else { return }
            self.move(tab, to: target)
            self.overview.reload()
        }
        // Échap : retour exact à la page d'avant (espace et onglet), même après en avoir parcouru d'autres.
        overview.onDismiss = { [weak self] in
            guard let self else { return }
            if let origin = self.sceneOrigin, self.spaces.contains(where: { $0 === origin.space }) {
                if origin.space !== self.currentSpace { self.switchTo(origin.space, announce: false) }
                if let tab = origin.tab, self.allTabs.contains(where: { $0 === tab }) { self.select(tab) }
            }
            self.closeOverview(expanding: self.activeTab?.id)
        }
        overview.onRenameSpace = { [weak self] id, name in self?.renameSpace(id, to: name) }
        overview.onShowSpace = { [weak self] id in
            guard let self, let space = self.space(id), space !== self.currentSpace else { return }
            self.switchTo(space, announce: false)
        }
    }

    /// Contenu d'un espace pour la Scène : épinglés, onglets (ordre stable), puis archivés.
    private func sceneContent(for spaceID: UUID) -> SceneContent {
        let list = tabsBySpace[spaceID] ?? []
        return SceneContent(pinned: list.filter(\.isPinned).map(card),
                            tabs: list.filter { !$0.isPinned }.map(card),
                            archived: archived.filter { $0.spaceID == spaceID }.map(card))
    }

    func showOverview() {
        guard overview.isHidden, !overviewOpening else { return }
        overviewOpening = true
        cancelSwitcher()
        if commandBar.isOpen { hideCommandBar() }
        sceneOrigin = (currentSpace, activeTab)
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
        if !overview.isHidden { overview.isHidden = true }
        // L'état de la CLI a pu changer (bw login fait dans le Terminal) : vérifié en arrière-plan.
        if !BitwardenService.shared.isUnlocked { Task { await BitwardenService.shared.refreshStatus() } }
        let opening = !commandBar.isOpen
        commandBar.present(text: newTab ? "" : (activeTab?.url?.absoluteString ?? ""), newTab: newTab, spaceName: currentSpace.name)
        window?.makeFirstResponder(commandBar.field)
        refreshResults(for: commandBar.query)
        if opening { setBarBackdrop(visible: true) }
    }

    private func hideCommandBar() {
        suggestionTask?.cancel()
        guard commandBar.isOpen else { return }
        commandBar.dismiss()
        setBarBackdrop(visible: false)
        // Sans page (espace vide), le clavier revient à la fenêtre : sinon il reste dans le champ caché
        // (la frappe se perd, et ⇧← ⇧→ sont désactivés comme dans un champ de texte).
        if let webView = displayedTab?.liveWebView { window?.makeFirstResponder(webView) } else { window?.makeFirstResponder(nil) }
    }

    /// Derrière la barre : la page recule d'un pas (98,5 %) et un voile uni se pose dessus.
    private func setBarBackdrop(visible: Bool) {
        if visible { veil.isHidden = false; veil.alphaValue = 0 }
        Design.Motion.animate(.medium, { self.veil.animator().alphaValue = visible ? 1 : 0 }) { [weak self] in
            guard let self, !visible, !self.commandBar.isOpen else { return }
            self.veil.isHidden = true
        }
        guard Design.Motion.allowsMovement(), let layer = pageContainer.layer else { return }
        let scale: CGFloat = 0.985, size = pageContainer.bounds.size
        let receded = CATransform3DConcat(CATransform3DMakeScale(scale, scale, 1),
                                          CATransform3DMakeTranslation(size.width * (1 - scale) / 2, size.height * (1 - scale) / 2, 0))
        let animation = CABasicAnimation(keyPath: "transform")
        animation.fromValue = layer.presentation()?.transform ?? (visible ? CATransform3DIdentity : receded)
        animation.toValue = visible ? receded : CATransform3DIdentity
        animation.duration = Design.Motion.duration(.slow)
        animation.timingFunction = Design.Motion.curve
        // Le recul n'existe que dans l'animation (la vue garde son cadre) : il reste tant que la barre est ouverte.
        animation.fillMode = .forwards
        animation.isRemovedOnCompletion = !visible
        layer.add(animation, forKey: "vision.recede")
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
                     bitwardenBusy: BitwardenService.shared.isBusy,
                     currentSpaceIsEmpty: tabs.isEmpty)
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
            guard !Task.isCancelled, let self, self.commandBar.isOpen, self.commandBar.query == query else { return }
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
    /// ⌥↩ remet l'élément dans le presse-papier. Touch ID d'abord pour un secret.
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

    /// Exécute le résultat choisi.
    /// - ↩ : action normale (ouvrir, basculer vers l'onglet, remplir dans l'espace de l'identifiant…).
    /// - ⌘↩ : toujours « l'autre onglet » : l'onglet actuel depuis Cmd+T (nouvel onglet depuis Cmd+L), pour tout
    ///   résultat qui a une adresse, y compris un onglet d'un autre espace (rouvert ici, avec les cookies d'ici).
    /// - ⌥↩ : copier (mot de passe, élément du presse-papier, adresse).
    private func execute(_ result: CommandResult?, typed: String, mode: CommandBarView.Submit) {
        let inNewTab = commandBar.isNewTab != (mode == .otherTab)
        hideCommandBar()
        guard let result else {
            if let input = AddressInput.parse(typed) { open(input.url, inNewTab: inNewTab) }
            return
        }
        if mode == .copy, !result.isCopyable, let url = result.url {
            return copyToPasteboard(url.absoluteString, toast: "Adresse copiée")
        }
        switch result.kind {
        case .openTab(let id, _):
            if mode == .otherTab || result.opensHere, let url = result.url { open(url, inNewTab: inNewTab) }
            else if let tab = tab(id) { select(tab) }
        case .archived(let id, _):
            if mode == .otherTab, let url = result.url { open(url, inNewTab: inNewTab) } else { reopenArchived(id) }
        case .clipboard(let id, _, _):
            useClipboardItem(id, copyOnly: mode == .copy)
        case .bitwarden(let id, _):
            switch mode {
            case .copy: if let item = BitwardenService.shared.vault.items.first(where: { $0.id == id }) { copyBitwardenPassword(item) }
            case .otherTab: useBitwardenItem(id, here: true, inNewTab: inNewTab)
            case .normal: useBitwardenItem(id, here: false, inNewTab: true)
            }
        case .command(.unlockBitwarden):
            unlockBitwardenAction(nil)
        case .command(.lockBitwarden):
            BitwardenService.shared.lock()
            domainToast.show(text: "Bitwarden verrouillé", symbol: "lock.fill", tint: .systemBlue)
        case .command(.setupBitwarden):
            showBitwardenSetup()
        case .command(.copyAddress):
            guard let url = activeTab?.url else { return }
            copyToPasteboard(url.absoluteString, toast: "Adresse copiée")
        case .command(.toggleFavorite):
            toggleFavoriteForActiveTab()
        case .command(.newSpace):
            newSpaceAction(nil)
        case .command(.renameSpace):
            renameSpaceAction(nil)
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

    private func copyToPasteboard(_ text: String, toast: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        domainToast.show(text: toast, symbol: "doc.on.doc.fill", tint: .systemOrange)
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

    /// Remplit un identifiant. Touch ID d'abord.
    /// - Parameter here: ⌘↩ : dans l'espace affiché (onglet actuel, ou nouvel onglet si `inNewTab` ou espace vide) ;
    ///   la page actuelle n'est pas rechargée si elle est déjà sur le bon site. Sinon (↩) : nouvel onglet dans
    ///   l'espace relié à l'identifiant (dossier Bitwarden, règle de routage).
    private func useBitwardenItem(_ id: String, here: Bool, inNewTab: Bool) {
        let service = BitwardenService.shared
        guard let item = service.vault.items.first(where: { $0.id == id }) else { return }
        guard let url = item.loginURL else {
            return domainToast.show(text: "Pas d'adresse web pour « \(item.name) »", symbol: "exclamationmark.triangle.fill", tint: .systemOrange)
        }
        // 1. La page s'ouvre tout de suite et charge pendant Touch ID et la lecture du mot de passe.
        let tab: BrowserTab
        if here, !inNewTab, let current = activeTab {
            tab = current
            if !BitwardenVault.pageMatches(current.url, item: item) { current.webView.load(URLRequest(url: url)) }
        } else {
            let space = here ? currentSpace : (service.vault.spaceID(for: item, config: config).flatMap(self.space) ?? currentSpace)
            tab = newTab(url: url, in: space, activate: true)
        }
        pendingFills[tab.id] = PendingFill(item: item, username: nil, password: nil, expires: Date().addingTimeInterval(180))
        Task { [weak self] in
            // 2. Touch ID et `bw get item` (~2,5 s) en même temps ; le mot de passe n'est gardé que si Touch ID réussit.
            async let credentials = service.credentials(for: id)
            let allowed = await service.authenticate(reason: "remplir l'identifiant « \(item.name) »")
            let result: (username: String?, password: String?)
            do { result = try await credentials } catch {
                self?.pendingFills[tab.id] = nil
                if allowed { self?.showError("Bitwarden", error) }
                return
            }
            guard let self, allowed, self.pendingFills[tab.id] != nil else { self?.pendingFills[tab.id] = nil; return }
            let fill = PendingFill(item: item, username: result.username, password: result.password,
                                   expires: Date().addingTimeInterval(180))
            self.pendingFills[tab.id] = fill
            // 3. Remplissage sans attendre la fin du chargement : le script guette l'apparition des champs.
            self.runFill(fill, in: tab)
        }
    }

    /// ⌥↩ : mot de passe dans le presse-papier (masqué dans l'historique, effacé après 90 s).
    private func copyBitwardenPassword(_ item: BitwardenItem) {
        let service = BitwardenService.shared
        Task { [weak self] in
            async let credentials = service.credentials(for: item.id)
            let allowed = await service.authenticate(reason: "copier le mot de passe « \(item.name) »")
            guard allowed, let password = try? await credentials.password, let self else { return }
            let clip = ClipboardItem(kind: .secret, text: password, source: "Bitwarden", copiedAt: Date(), fromBitwarden: true)
            ClipboardMonitor.shared.write(clip)
            ClipboardMonitor.shared.record(clip)
            ClipboardMonitor.shared.clearLater(after: .seconds(90))
            self.domainToast.show(text: "Mot de passe copié (effacé dans 90 s)", symbol: "key.fill", tint: .systemBlue)
        }
    }

    /// Relance un remplissage en attente (nouvelle page chargée ou adresse changée dans l'onglet).
    private func resumeFill(in tab: BrowserTab) {
        guard let fill = pendingFills[tab.id] else { return }
        if fill.expires < Date() { pendingFills[tab.id] = nil; return }
        runFill(fill, in: tab)
    }

    /// Remplit l'onglet si la page est bien sur le site enregistré (garde-fou anti-hameçonnage).
    private func runFill(_ fill: PendingFill, in tab: BrowserTab) {
        guard fill.username != nil || fill.password != nil,
              let view = tab.liveWebView, BitwardenVault.pageMatches(tab.url, item: fill.item) else { return }
        let arguments: [String: Any] = ["username": fill.username ?? "", "password": fill.password ?? "",
                                        "site": tab.url?.host()?.lowercased() ?? "", "token": UUID().uuidString]
        Task { [weak self] in
            let result = try? await view.callAsyncJavaScript(LoginFiller.script, arguments: arguments, contentWorld: EscapeRelay.world)
            guard let self, (result as? String) == "filled", self.pendingFills[tab.id] != nil else { return }
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
        if commandBar.isOpen { return hideCommandBar() }
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
    /// Précédent ; sur une page ouverte dans un nouvel onglet par un lien (document, PDF), sans historique :
    /// ferme l'onglet et revient à la page d'origine.
    @objc func goBackAction(_ sender: Any?) {
        guard let tab = activeTab else { return }
        if tab.webView.canGoBack { tab.webView.goBack(); return }
        guard let opener = tab.opener, allTabs.contains(where: { $0 === opener }) else { return }
        close(tab)
        select(opener)
    }
    @objc func goForwardAction(_ sender: Any?) { activeTab?.webView.goForward() }
    @objc func zoomInAction(_ sender: Any?) { activeTab.map { $0.webView.pageZoom = min($0.webView.pageZoom + 0.1, 3) } }
    @objc func zoomOutAction(_ sender: Any?) { activeTab.map { $0.webView.pageZoom = max($0.webView.pageZoom - 0.1, 0.3) } }
    @objc func zoomResetAction(_ sender: Any?) { activeTab?.webView.pageZoom = 1 }
    @objc func nextTabAction(_ sender: Any?) { cycleTabs(by: 1) }
    @objc func previousTabAction(_ sender: Any?) { cycleTabs(by: -1) }
    @objc func selectTabByNumberAction(_ sender: Any?) {
        if let n = (sender as? NSMenuItem)?.tag { selectTab(number: n) }
    }
    /// ⌘1…8 : onglet n de l'espace ; ⌘9 : le dernier.
    private func selectTab(number n: Int) {
        guard !tabs.isEmpty else { return }
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
        if let n = (sender as? NSMenuItem)?.tag { switchSpace(number: n) }
    }
    /// ⇧← / ⇧→ : espace précédent / suivant (en boucle), sur la page comme dans la vue d'ensemble.
    @objc func previousSpaceAction(_ sender: Any?) { stepSpace(by: -1) }
    @objc func nextSpaceAction(_ sender: Any?) { stepSpace(by: 1) }
    private func stepSpace(by step: Int) {
        guard let i = spaces.firstIndex(where: { $0 === currentSpace }), spaces.count > 1 else { return }
        spaceStepHint = step
        switchSpace(number: (i + step + spaces.count) % spaces.count + 1)
        spaceStepHint = nil
    }

    private func switchSpace(number n: Int) {
        guard spaces.indices.contains(n - 1) else { return }
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
        // ⌘← ⌘→ appartiennent au champ de texte en cours de saisie (barre Cmd+T, dialogues) : début / fin de ligne.
        // ⇧← ⇧→ : sélection de texte dans un champ de l'app.
        case #selector(previousSpaceAction(_:)), #selector(nextSpaceAction(_:)):
            return spaces.count > 1 && !(window?.firstResponder is NSText)
        case #selector(goBackAction(_:)), #selector(goForwardAction(_:)):
            return activeTab != nil && !(window?.firstResponder is NSText)
        case #selector(togglePinAction(_:)):
            item.title = targetTab?.isPinned == true ? "Désépingler l'onglet" : "Épingler l'onglet"
            return targetTab != nil
        default: return true
        }
    }

    // MARK: NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) { host.controller.didFocusWindow(self) }
    func windowDidEnterFullScreen(_ notification: Notification) { updateToastInset() }
    func windowDidExitFullScreen(_ notification: Notification) { updateToastInset() }
    func windowDidChangeScreen(_ notification: Notification) { updateToastInset() }

    /// En plein écran sur un Mac à encoche, la fenêtre peut monter jusque derrière l'encoche :
    /// l'étiquette descend alors d'autant, pour rester lisible (rien d'interactif ne se place sous l'encoche).
    private func updateToastInset() {
        guard let window, let screen = window.screen else { return }
        let safeTop = screen.frame.maxY - screen.safeAreaInsets.top
        toastTop?.constant = 12 + max(0, window.frame.maxY - safeTop)
    }
    func windowDidResignKey(_ notification: Notification) {
        cancelSwitcher()
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

/// Voile uni posé sur la page derrière la barre Cmd+T (couleur de `Design.Palette.veil`).
@MainActor
final class VeilView: NSView {
    var onClick: (() -> Void)?
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = Design.Palette.veil.cgColor
        isHidden = true
    }
    required init?(coder: NSCoder) { fatalError("non utilisé") }
    override func mouseDown(with event: NSEvent) { onClick?() }
}

private extension NSLayoutConstraint {
    func withPriority(_ priority: NSLayoutConstraint.Priority) -> NSLayoutConstraint {
        self.priority = priority
        return self
    }
}
