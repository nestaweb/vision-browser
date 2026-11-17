import AppKit

/// Contenu d'un espace pour la vue d'ensemble, préparé par la fenêtre.
struct OverviewContent {
    enum Group {
        case single(TabCard)
        case stack(site: String, cards: [TabCard])
    }
    struct Favorite { var title: String; var url: URL }

    var pinned: [TabCard] = []
    var groups: [Group] = []
    var archived: [TabCard] = []
    var favorites: [Favorite] = []

    var allTabCards: [TabCard] {
        groups.flatMap { group -> [TabCard] in
            switch group {
            case .single(let card): [card]
            case .stack(_, let cards): cards
            }
        }
    }
}

/// Vue d'ensemble (F2, niveau 2b) : toutes les cartes d'un espace, rangées en sections.
/// Ordre stable (création), 3 densités, piles par site, filtre au clavier, glisser-déposer.
@MainActor
final class OverviewView: NSView {
    struct SpaceInfo { var id: UUID; var name: String; var color: NSColor }

    // Données et actions fournies par la fenêtre.
    var contentProvider: ((UUID) -> OverviewContent)?
    var onOpenTab: ((UUID) -> Void)?
    var onCloseTab: ((UUID) -> Void)?
    var onHome: ((UUID) -> Void)?
    var onReopenArchived: ((UUID) -> Void)?
    var onOpenFavorite: ((URL, UUID) -> Void)?
    var onPin: ((UUID, Bool) -> Void)?
    var onMove: ((UUID, UUID) -> Void)?
    var onDismiss: (() -> Void)?

    private(set) var spaces: [SpaceInfo] = []
    private(set) var shownSpaceID: UUID?
    private(set) var focusedID: UUID?
    private var filter = ""
    private var expandedSites: Set<String> = []
    private var favoritesExpanded = false
    private var density: Int {
        get { min(max(UserDefaults.standard.integer(forKey: "VBOverviewDensity"), 0), 2) }
        set { UserDefaults.standard.set(min(max(newValue, 0), 2), forKey: "VBOverviewDensity") }
    }
    private static let columns = [3, 5, 8]

    private let background = NSVisualEffectView()
    private let header = FlippedView()
    private let filterLabel = NSTextField(labelWithString: "")
    private let densityControl = NSSegmentedControl(labels: ["Grandes", "Moyennes", "Petites"], trackingMode: .selectOne, target: nil, action: nil)
    private let scrollView = OverviewScrollView()
    private let document = FlippedView()
    private var spaceChips: [SpaceChip] = []
    /// Cartes focalisables, dans l'ordre d'affichage (flèches du clavier).
    private var focusables: [(id: UUID, view: TabCardView, action: () -> Void)] = []
    private var activeCardFrame: NSRect?
    private var pinchAccumulator: CGFloat = 0
    private var swipeAccumulator: CGFloat = 0
    private var lastSwipe = Date.distantPast

    override init(frame: NSRect) {
        super.init(frame: frame)
        background.material = .underWindowBackground
        background.blendingMode = .withinWindow
        background.state = .active
        filterLabel.font = .systemFont(ofSize: 13)
        filterLabel.textColor = .secondaryLabelColor
        densityControl.segmentStyle = .rounded
        densityControl.controlSize = .small
        densityControl.target = self
        densityControl.action = #selector(densityChanged)
        densityControl.toolTip = "Taille des cartes (pincer pour changer)"
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.documentView = document
        scrollView.onHorizontalSwipe = { [weak self] dx, phaseEnded in self?.handleSwipe(dx, ended: phaseEnded) }
        for view in [background, scrollView, header] { addSubview(view) }
        header.addSubview(filterLabel)
        header.addSubview(densityControl)
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("non utilisé") }

    override var acceptsFirstResponder: Bool { true }

    // MARK: Ouverture et fermeture (animation de zoom)

    /// Ouvre la vue sur un espace. La page affichée rétrécit jusqu'à sa carte.
    func present(spaces: [SpaceInfo], showing spaceID: UUID, activeTabID: UUID?, pageImage: NSImage?) {
        self.spaces = spaces
        shownSpaceID = spaceID
        filter = ""
        expandedSites = []
        focusedID = activeTabID
        isHidden = false
        alphaValue = 1
        window?.makeFirstResponder(self)
        reload()
        layoutSubtreeIfNeeded()
        scrollToFocused()
        guard let pageImage, let target = activeCardFrame.map({ convert($0, from: document) }) else { return }
        animateZoom(image: pageImage, from: bounds, to: target, fadeIn: true, completion: nil)
    }

    /// Ferme la vue en agrandissant une carte jusqu'à la fenêtre (ou par un simple fondu).
    func dismiss(expanding cardID: UUID?, completion: @escaping () -> Void) {
        if let cardID, let entry = focusables.first(where: { $0.id == cardID }), !entry.view.isHidden {
            let from = convert(entry.view.frame, from: document)
            animateZoom(image: entry.view.card.image, from: from, to: bounds, fadeIn: false) { [weak self] in
                self?.isHidden = true
                completion()
            }
        } else {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.15
                MainActor.assumeIsolated { self.animator().alphaValue = 0 }
            }, completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    self?.isHidden = true
                    completion()
                }
            })
        }
    }

    private func animateZoom(image: NSImage?, from: NSRect, to: NSRect, fadeIn: Bool, completion: (() -> Void)?) {
        let layer = CALayer()
        layer.contents = image
        layer.contentsGravity = .resizeAspectFill
        layer.masksToBounds = true
        layer.cornerRadius = fadeIn ? 0 : 10
        layer.backgroundColor = NSColor.windowBackgroundColor.cgColor
        layer.frame = from
        layer.zPosition = 100
        self.layer?.addSublayer(layer)
        scrollView.alphaValue = fadeIn ? 0 : 1
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.28)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        CATransaction.setCompletionBlock {
            MainActor.assumeIsolated {
                layer.removeFromSuperlayer()
                completion?()
            }
        }
        layer.frame = to
        layer.cornerRadius = fadeIn ? 10 : 0
        CATransaction.commit()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.28
            MainActor.assumeIsolated { self.scrollView.animator().alphaValue = fadeIn ? 1 : 0 }
        }
    }

    // MARK: Construction

    private var content: OverviewContent {
        shownSpaceID.flatMap { contentProvider?($0) } ?? OverviewContent()
    }

    func reload() {
        guard !isHidden, shownSpaceID != nil else { return }
        rebuildHeader()
        document.subviews.forEach { $0.removeFromSuperview() }
        focusables = []
        activeCardFrame = nil
        let content = self.content
        let filtering = !filter.trimmingCharacters(in: .whitespaces).isEmpty
        let matches = { (card: TabCard) in TabOrganizer.matches(title: card.title, url: card.url, filter: self.filter) }

        var sections: [(title: String, cards: [TabCardView], drop: ((UUID) -> Void)?, hint: String?)] = []
        let pinned = content.pinned.filter(matches).map { makeCard($0) }
        sections.append(("Épinglés", pinned, { [weak self] id in self?.onPin?(id, true) },
                         pinned.isEmpty && !filtering ? "Glisse une carte ici pour l'épingler (ou ⌘D)" : nil))

        var tabViews: [TabCardView] = []
        for group in content.groups {
            switch group {
            case .single(let card) where matches(card):
                tabViews.append(makeCard(card))
            case .stack(let site, let cards):
                let shown = cards.filter(matches)
                if filtering || expandedSites.contains(site) { tabViews += shown.map { makeCard($0) } }
                else if let first = shown.first {
                    var top = first
                    top.title = site
                    top.host = "\(shown.count) onglets"
                    top.isActive = shown.contains { $0.isActive }
                    let view = makeCard(top, action: { [weak self] in
                        self?.expandedSites.insert(site)
                        self?.reload()
                    })
                    view.stackCount = shown.count
                    view.showsCloseButton = false
                    tabViews.append(view)
                }
            default: break
            }
        }
        sections.append(("Onglets", tabViews, { [weak self] id in self?.onPin?(id, false) },
                         tabViews.isEmpty && !filtering ? "Aucun onglet dans cet espace" : nil))

        let archived = content.archived.filter(matches).prefix(filtering ? 50 : 24).map { card in
            makeCard(card, action: { [weak self] in self?.onReopenArchived?(card.id) }, draggable: false)
        }
        if !archived.isEmpty { sections.append(("Archivés", Array(archived), nil, nil)) }

        var y: CGFloat = 8
        let width = max(scrollView.contentSize.width, 300)
        let inset: CGFloat = 40, gap: CGFloat = 18
        let cols = CGFloat(Self.columns[density])
        let cardWidth = floor((width - 2 * inset - gap * (cols - 1)) / cols)
        let cardHeight = floor(cardWidth * 0.62) + (cardWidth < 130 ? 20 : TabCardView.captionHeight)

        for section in sections {
            let container = SectionDropView()
            container.onDrop = section.drop
            let title = NSTextField(labelWithString: section.title.uppercased())
            title.font = .systemFont(ofSize: 11, weight: .semibold)
            title.textColor = .secondaryLabelColor
            container.addSubview(title)
            title.frame = NSRect(x: 0, y: 0, width: 300, height: 16)
            var rowY: CGFloat = 26
            if let hint = section.hint {
                let label = NSTextField(labelWithString: hint)
                label.textColor = .tertiaryLabelColor
                label.frame = NSRect(x: 0, y: rowY, width: width - 2 * inset, height: 20)
                container.addSubview(label)
                rowY += 34
            }
            for (i, card) in section.cards.enumerated() {
                let col = CGFloat(i % Int(cols)), row = CGFloat(i / Int(cols))
                card.frame = NSRect(x: col * (cardWidth + gap), y: rowY + row * (cardHeight + gap), width: cardWidth, height: cardHeight)
                container.addSubview(card)
            }
            let rows = ceil(CGFloat(section.cards.count) / cols)
            let height = rowY + rows * (cardHeight + gap) + 8
            container.frame = NSRect(x: inset, y: y, width: width - 2 * inset, height: height)
            document.addSubview(container)
            for card in section.cards where card.card.isActive {
                activeCardFrame = container.convert(card.frame, to: document)
            }
            y += height + 18
        }

        y = addFavorites(content.favorites.filter { TabOrganizer.matches(title: $0.title, url: $0.url, filter: filter) },
                         at: y, inset: inset, width: width)
        if filtering && focusables.isEmpty {
            let empty = NSTextField(labelWithString: "Rien ne correspond à « \(filter) » dans cet espace.")
            empty.textColor = .secondaryLabelColor
            empty.frame = NSRect(x: inset, y: y, width: width - 2 * inset, height: 20)
            document.addSubview(empty)
            y += 40
        }
        document.frame = NSRect(x: 0, y: 0, width: width, height: max(y + 20, scrollView.contentSize.height))
        if focusedID == nil || !focusables.contains(where: { $0.id == focusedID }) {
            focusedID = filtering ? focusables.first?.id : focusables.first(where: { $0.view.card.isActive })?.id
        }
        markFocus()
    }

    private func addFavorites(_ favorites: [OverviewContent.Favorite], at y: CGFloat, inset: CGFloat, width: CGFloat) -> CGFloat {
        guard !favorites.isEmpty else { return y }
        var y = y
        let toggle = NSButton(title: "\(favoritesExpanded ? "▾" : "▸")  FAVORIS (\(favorites.count))", target: self, action: #selector(toggleFavorites))
        toggle.isBordered = false
        toggle.font = .systemFont(ofSize: 11, weight: .semibold)
        toggle.contentTintColor = .secondaryLabelColor
        toggle.frame = NSRect(x: inset, y: y, width: 240, height: 18)
        document.addSubview(toggle)
        y += 26
        guard favoritesExpanded || !filter.isEmpty else { return y + 10 }
        for favorite in favorites.prefix(30) {
            let button = NSButton(title: "★  \(favorite.title)   \(PlacesStore.host(favorite.url))", target: nil, action: nil)
            button.isBordered = false
            button.alignment = .left
            button.lineBreakMode = .byTruncatingTail
            button.frame = NSRect(x: inset + 4, y: y, width: width - 2 * inset, height: 20)
            let url = favorite.url
            button.target = self
            button.action = #selector(favoriteClicked(_:))
            button.identifier = NSUserInterfaceItemIdentifier(url.absoluteString)
            document.addSubview(button)
            y += 24
        }
        return y + 10
    }

    private func makeCard(_ card: TabCard, action: (() -> Void)? = nil, draggable: Bool = true) -> TabCardView {
        let view = TabCardView(card: card)
        view.showsCloseButton = !card.isArchived
        view.isDraggable = draggable && !card.isArchived
        let open = action ?? { [weak self] in self?.onOpenTab?(card.id) }
        view.onClick = open
        view.onClose = { [weak self] in self?.onCloseTab?(card.id) }
        view.onHome = { [weak self] in self?.onHome?(card.id) }
        focusables.append((card.id, view, open))
        return view
    }

    private func rebuildHeader() {
        spaceChips.forEach { $0.removeFromSuperview() }
        let filtering = !filter.trimmingCharacters(in: .whitespaces).isEmpty
        spaceChips = spaces.map { space in
            let content = contentProvider?(space.id) ?? OverviewContent()
            let cards = content.pinned + content.allTabCards
            let count = filtering ? cards.filter { TabOrganizer.matches(title: $0.title, url: $0.url, filter: filter) }.count : cards.count
            let chip = SpaceChip(name: space.name, color: space.color, count: count, isShown: space.id == shownSpaceID)
            chip.onClick = { [weak self] in self?.show(space: space.id) }
            chip.onDrop = { [weak self] tabID in self?.onMove?(tabID, space.id) }
            return chip
        }
        spaceChips.forEach(header.addSubview)
        filterLabel.stringValue = filtering ? "⌕ \(filter)   ·   Échap pour effacer" : "Tape pour filtrer   ·   ⇧← ⇧→ espaces   ·   Échap pour revenir"
        densityControl.selectedSegment = density
        needsLayout = true
    }

    override func layout() {
        super.layout()
        background.frame = bounds
        header.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 70)
        var x: CGFloat = 40
        for chip in spaceChips {
            let size = chip.fittingSize
            chip.frame = NSRect(x: x, y: 26, width: size.width, height: 28)
            x += size.width + 8
        }
        densityControl.sizeToFit()
        densityControl.frame.origin = NSPoint(x: bounds.width - densityControl.frame.width - 40, y: 28)
        filterLabel.frame = NSRect(x: x + 16, y: 32, width: max(densityControl.frame.minX - x - 32, 0), height: 18)
        scrollView.frame = NSRect(x: 0, y: 70, width: bounds.width, height: bounds.height - 70)
        if abs(document.frame.width - scrollView.contentSize.width) > 1 { reload() }
    }

    override var isFlipped: Bool { true }

    // MARK: Navigation

    func show(space id: UUID) {
        guard id != shownSpaceID else { return }
        shownSpaceID = id
        expandedSites = []
        focusedID = nil
        reload()
    }

    private func stepSpace(_ step: Int) {
        guard let current = spaces.firstIndex(where: { $0.id == shownSpaceID }), spaces.count > 1 else { return }
        show(space: spaces[(current + step + spaces.count) % spaces.count].id)
    }

    private func markFocus() {
        for entry in focusables { entry.view.isFocused = entry.id == focusedID }
    }

    private func scrollToFocused() {
        guard let view = focusables.first(where: { $0.id == focusedID })?.view, let container = view.superview else { return }
        document.scrollToVisible(container.convert(view.frame, to: document).insetBy(dx: 0, dy: -20))
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) || flags.contains(.control) { return super.keyDown(with: event) }
        switch event.keyCode {
        case 53: // Échap
            if filter.isEmpty { onDismiss?() } else { filter = ""; focusedID = nil; reload() }
        case 36, 76: // Entrée
            (focusables.first { $0.id == focusedID } ?? focusables.first)?.action()
        case 51: // Effacement
            if !filter.isEmpty { filter.removeLast(); focusedID = nil; reload() }
        case 123, 124 where flags.contains(.shift):
            stepSpace(event.keyCode == 124 ? 1 : -1)
        case 123, 124, 125, 126:
            moveFocus(keyCode: event.keyCode)
        default:
            guard let text = event.characters, !text.isEmpty, text.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
                  text != " " || !filter.isEmpty else { return super.keyDown(with: event) }
            filter += text
            focusedID = nil
            reload()
        }
    }

    private func moveFocus(keyCode: UInt16) {
        guard !focusables.isEmpty else { return }
        let cols = Self.columns[density]
        var i = focusables.firstIndex { $0.id == focusedID } ?? 0
        switch keyCode {
        case 123: i -= 1
        case 124: i += 1
        case 125: i += cols
        default: i -= cols
        }
        focusedID = focusables[min(max(i, 0), focusables.count - 1)].id
        markFocus()
        scrollToFocused()
    }

    /// Pincer : rapprocher les doigts rétrécit les cartes ; les écarter les agrandit, puis entre dans la carte.
    override func magnify(with event: NSEvent) {
        if event.phase == .began { pinchAccumulator = 0 }
        pinchAccumulator += event.magnification
        if pinchAccumulator < -0.12 {
            pinchAccumulator = 0
            if density < 2 { density += 1; reload() }
        } else if pinchAccumulator > 0.12 {
            pinchAccumulator = 0
            if density > 0 { density -= 1; reload() }
            else if let entry = focusables.first(where: { $0.id == focusedID }) { entry.action() }
        }
    }

    /// Balayage horizontal à deux doigts : espace voisin.
    private func handleSwipe(_ dx: CGFloat, ended: Bool) {
        if ended { swipeAccumulator = 0; return }
        swipeAccumulator += dx
        guard abs(swipeAccumulator) > 60, Date().timeIntervalSince(lastSwipe) > 0.5 else { return }
        stepSpace(swipeAccumulator < 0 ? 1 : -1)
        swipeAccumulator = 0
        lastSwipe = Date()
    }

    @objc private func densityChanged() {
        density = densityControl.selectedSegment
        reload()
    }

    @objc private func toggleFavorites() {
        favoritesExpanded.toggle()
        reload()
    }

    @objc private func favoriteClicked(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let url = URL(string: raw), let space = shownSpaceID else { return }
        onOpenFavorite?(url, space)
    }

    /// Identifiant de l'onglet focalisé (pour ⌘D et ⌘W dans la vue d'ensemble).
    var focusedTabID: UUID? { isHidden ? nil : focusedID }
}

/// Défilement de la vue d'ensemble : les balayages horizontaux changent d'espace au lieu de défiler.
final class OverviewScrollView: NSScrollView {
    var onHorizontalSwipe: ((CGFloat, Bool) -> Void)?
    override func scrollWheel(with event: NSEvent) {
        if abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) * 1.2 {
            onHorizontalSwipe?(event.scrollingDeltaX, event.phase == .ended || event.momentumPhase == .ended)
        } else {
            super.scrollWheel(with: event)
        }
    }
}

/// Section qui accepte une carte déposée (Épinglés : épingler ; Onglets : désépingler).
final class SectionDropView: FlippedView {
    var onDrop: ((UUID) -> Void)? {
        didSet { onDrop == nil ? unregisterDraggedTypes() : registerForDraggedTypes([.visionTab]) }
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.08).cgColor
        return .move
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) { layer?.backgroundColor = nil }

    private var droppedID: UUID?

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        layer?.backgroundColor = nil
        guard let raw = sender.draggingPasteboard.string(forType: .visionTab), let id = UUID(uuidString: raw) else { return false }
        // Laisser la session de glisser se terminer avant de reconstruire la vue (la carte source disparaît).
        droppedID = id
        perform(#selector(finishDrop), with: nil, afterDelay: 0)
        return true
    }

    @objc private func finishDrop() {
        if let id = droppedID { onDrop?(id) }
        droppedID = nil
    }
}

/// Pastille d'espace dans l'en-tête : cliquer pour l'afficher, y déposer une carte pour y envoyer l'onglet.
final class SpaceChip: NSView {
    var onClick: (() -> Void)?
    var onDrop: ((UUID) -> Void)?
    private let label = NSTextField(labelWithString: "")
    private let color: NSColor
    private let isShown: Bool

    init(name: String, color: NSColor, count: Int, isShown: Bool) {
        self.color = color
        self.isShown = isShown
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 14
        label.attributedStringValue = NSAttributedString(string: "●  \(name)  \(count)", attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: isShown ? .semibold : .regular),
            .foregroundColor: isShown ? NSColor.labelColor : NSColor.secondaryLabelColor,
        ])
        let colored = NSMutableAttributedString(attributedString: label.attributedStringValue)
        colored.addAttribute(.foregroundColor, value: color, range: NSRange(location: 0, length: 1))
        label.attributedStringValue = colored
        addSubview(label)
        resetBackground()
        registerForDraggedTypes([.visionTab])
    }

    required init?(coder: NSCoder) { fatalError("non utilisé") }

    override var fittingSize: NSSize { NSSize(width: label.fittingSize.width + 26, height: 28) }
    override func layout() {
        super.layout()
        label.frame = NSRect(x: 13, y: (bounds.height - 17) / 2, width: bounds.width - 26, height: 17)
    }
    override func mouseUp(with event: NSEvent) { onClick?() }

    private func resetBackground() {
        layer?.backgroundColor = isShown ? color.withAlphaComponent(0.18).cgColor : NSColor.quaternaryLabelColor.cgColor
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        layer?.backgroundColor = color.withAlphaComponent(0.4).cgColor
        return .move
    }
    override func draggingExited(_ sender: (any NSDraggingInfo)?) { resetBackground() }
    private var droppedID: UUID?

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        resetBackground()
        guard let raw = sender.draggingPasteboard.string(forType: .visionTab), let id = UUID(uuidString: raw) else { return false }
        droppedID = id
        perform(#selector(finishDrop), with: nil, afterDelay: 0)
        return true
    }

    @objc private func finishDrop() {
        if let id = droppedID { onDrop?(id) }
        droppedID = nil
    }
}
