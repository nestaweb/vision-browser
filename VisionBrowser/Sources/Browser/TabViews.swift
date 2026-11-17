import AppKit

/// Ce qu'une carte affiche (étagère, vue d'ensemble, sélecteur Ctrl+Tab).
struct TabCard {
    var id: UUID
    var title: String
    var host: String
    var url: URL?
    var image: NSImage?
    var spaceColor: NSColor
    var isPinned = false
    var isActive = false
    var isArchived = false
    /// Épinglé et parti de sa page d'accueil : le bouton ↺ y ramène.
    var canGoHome = false
}

extension NSPasteboard.PasteboardType {
    /// Glisser-déposer d'une carte : l'identifiant de l'onglet.
    static let visionTab = NSPasteboard.PasteboardType("app.visionbrowser.tab")
}

/// Vue retournée (origine en haut à gauche) : plus simple pour les mises en page manuelles.
class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// Une carte d'onglet : capture de la page (jamais une page vivante), titre, site.
@MainActor
final class TabCardView: FlippedView, NSDraggingSource {
    var card: TabCard { didSet { refresh() } }
    var isFocused = false { didSet { updateRing() } }
    /// Nombre d'onglets si la carte représente une pile repliée.
    var stackCount = 0 { didSet { refresh() } }
    var showsCloseButton = false
    var isDraggable = false
    var onClick: (() -> Void)?
    var onClose: (() -> Void)?
    var onHome: (() -> Void)?

    private let preview = NSView()
    private let placeholder = NSTextField(labelWithString: "")
    private let titleLabel = NSTextField(labelWithString: "")
    private let hostLabel = NSTextField(labelWithString: "")
    private let pinBadge = NSImageView()
    private let countBadge = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    private let homeButton = NSButton()
    private let behind = [CALayer(), CALayer()]
    private var mouseDownPoint: NSPoint?
    private var dragged = false
    static let captionHeight: CGFloat = 36

    init(card: TabCard) {
        self.card = card
        super.init(frame: .zero)
        wantsLayer = true
        for layer in behind {
            layer.cornerRadius = 10
            layer.backgroundColor = NSColor.secondaryLabelColor.withAlphaComponent(0.25).cgColor
            layer.isHidden = true
            self.layer?.addSublayer(layer)
        }
        layer?.masksToBounds = false
        preview.wantsLayer = true
        preview.layer?.cornerRadius = 10
        preview.layer?.masksToBounds = true
        preview.layer?.contentsGravity = .resizeAspectFill
        preview.layer?.borderWidth = 1
        placeholder.font = .systemFont(ofSize: 30, weight: .semibold)
        placeholder.textColor = .white
        placeholder.alignment = .center
        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingTail
        hostLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        hostLabel.textColor = .secondaryLabelColor
        hostLabel.lineBreakMode = .byTruncatingMiddle
        pinBadge.image = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: "Épinglé")
        pinBadge.contentTintColor = .white
        pinBadge.wantsLayer = true
        pinBadge.layer?.cornerRadius = 9
        countBadge.font = .systemFont(ofSize: 11, weight: .bold)
        countBadge.textColor = .white
        countBadge.alignment = .center
        countBadge.wantsLayer = true
        countBadge.layer?.cornerRadius = 9
        countBadge.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.65).cgColor
        for (button, symbol, label) in [(closeButton, "xmark.circle.fill", "Fermer l'onglet"),
                                        (homeButton, "arrow.counterclockwise.circle.fill", "Revenir à la page d'accueil de l'onglet")] {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            button.isBordered = false
            button.imageScaling = .scaleProportionallyUpOrDown
            button.contentTintColor = .white
            button.toolTip = label
            button.target = self
        }
        closeButton.action = #selector(closeClicked)
        homeButton.action = #selector(homeClicked)
        closeButton.isHidden = true
        preview.addSubview(placeholder)
        for view in [preview, titleLabel, hostLabel, pinBadge, countBadge, homeButton, closeButton] { addSubview(view) }
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("non utilisé") }

    private func refresh() {
        titleLabel.stringValue = card.title
        hostLabel.stringValue = card.host
        if let image = card.image {
            preview.layer?.contents = image
            preview.layer?.backgroundColor = NSColor.white.cgColor
            placeholder.isHidden = true
        } else {
            preview.layer?.contents = nil
            preview.layer?.backgroundColor = card.spaceColor.withAlphaComponent(0.55).cgColor
            placeholder.stringValue = String(card.host.first ?? "•").uppercased()
            placeholder.isHidden = false
        }
        pinBadge.isHidden = !card.isPinned
        pinBadge.layer?.backgroundColor = card.spaceColor.cgColor
        homeButton.isHidden = !card.canGoHome
        countBadge.isHidden = stackCount < 2
        countBadge.stringValue = "\(stackCount)"
        behind.forEach { $0.isHidden = stackCount < 2 }
        alphaValue = card.isArchived ? 0.7 : 1
        updateRing()
        needsLayout = true
    }

    private func updateRing() {
        let color: NSColor = isFocused ? .controlAccentColor : (card.isActive ? card.spaceColor : .separatorColor)
        preview.layer?.borderColor = color.cgColor
        preview.layer?.borderWidth = isFocused || card.isActive ? 3 : 1
    }

    override func layout() {
        super.layout()
        let compact = bounds.width < 130
        let caption = compact ? 20 : Self.captionHeight
        preview.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(bounds.height - caption, 10))
        for (i, layer) in behind.enumerated() {
            let offset = CGFloat(i + 1) * 4
            layer.frame = preview.frame.offsetBy(dx: offset, dy: -offset).insetBy(dx: offset, dy: 0)
            layer.zPosition = -1
        }
        placeholder.frame = NSRect(x: 0, y: preview.bounds.midY - 20, width: preview.bounds.width, height: 40)
        titleLabel.frame = NSRect(x: 2, y: preview.frame.maxY + 3, width: bounds.width - 4, height: 16)
        hostLabel.frame = NSRect(x: 2, y: preview.frame.maxY + 19, width: bounds.width - 4, height: 14)
        hostLabel.isHidden = compact
        pinBadge.frame = NSRect(x: 6, y: 6, width: 18, height: 18)
        countBadge.frame = NSRect(x: preview.frame.maxX - 30, y: preview.frame.maxY - 26, width: 24, height: 18)
        closeButton.frame = NSRect(x: bounds.width - 24, y: 4, width: 20, height: 20)
        homeButton.frame = NSRect(x: card.isPinned ? 28 : 6, y: 5, width: 18, height: 18)
    }

    // MARK: Souris

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { closeButton.isHidden = !showsCloseButton }
    override func mouseExited(with event: NSEvent) { closeButton.isHidden = true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = convert(event.locationInWindow, from: nil)
        dragged = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDraggable, !dragged, let start = mouseDownPoint else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - start.x, point.y - start.y) > 5 else { return }
        dragged = true
        let item = NSPasteboardItem()
        item.setString(card.id.uuidString, forType: .visionTab)
        let draggingItem = NSDraggingItem(pasteboardWriter: item)
        draggingItem.setDraggingFrame(bounds, contents: snapshotImage())
        beginDraggingSession(with: [draggingItem], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        defer { mouseDownPoint = nil }
        guard !dragged, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onClick?()
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }

    private func snapshotImage() -> NSImage {
        guard let rep = bitmapImageRepForCachingDisplay(in: bounds) else { return NSImage() }
        cacheDisplay(in: bounds, to: rep)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(rep)
        return image
    }

    @objc private func closeClicked() { onClose?() }
    @objc private func homeClicked() { onHome?() }
}

/// Sélecteur `Ctrl+Tab` : les onglets de l'espace par ordre d'utilisation récente.
@MainActor
final class TabSwitcherView: NSVisualEffectView {
    private var cardViews: [TabCardView] = []
    private(set) var selected = 0
    private let cardSize = NSSize(width: 190, height: 150)

    override init(frame: NSRect) {
        super.init(frame: frame)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 18
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("non utilisé") }

    func show(cards: [TabCard], selected: Int) {
        cardViews.forEach { $0.removeFromSuperview() }
        cardViews = cards.map { TabCardView(card: $0) }
        cardViews.forEach(addSubview)
        isHidden = false
        select(selected)
    }

    func select(_ index: Int) {
        guard !cardViews.isEmpty else { return }
        selected = (index % cardViews.count + cardViews.count) % cardViews.count
        for (i, view) in cardViews.enumerated() { view.isFocused = i == selected }
        needsLayout = true
    }

    /// Taille voulue : au plus la largeur de la fenêtre, les cartes au-delà défilent autour de la sélection.
    func preferredSize(maxWidth: CGFloat) -> NSSize {
        let fit = max(1, Int((maxWidth - 40) / (cardSize.width + 14)))
        let count = min(cardViews.count, fit)
        return NSSize(width: CGFloat(count) * (cardSize.width + 14) + 26, height: cardSize.height + 40)
    }

    override func layout() {
        super.layout()
        let fit = max(1, Int((bounds.width - 26) / (cardSize.width + 14)))
        let first = min(max(0, selected - fit / 2), max(0, cardViews.count - fit))
        for (i, view) in cardViews.enumerated() {
            let slot = i - first
            view.isHidden = slot < 0 || slot >= fit
            view.frame = NSRect(x: 20 + CGFloat(slot) * (cardSize.width + 14), y: 20, width: cardSize.width, height: cardSize.height)
        }
    }
}

/// Étagère du bas (F2, niveau 2a) : espaces, épinglés, 6 onglets récents, « Tout voir ».
/// Elle garde la même taille quel que soit le nombre d'onglets.
@MainActor
final class ShelfView: NSVisualEffectView {
    struct SpaceItem { var id: UUID; var name: String; var color: NSColor; var count: Int; var isCurrent: Bool }

    var onSelectTab: ((UUID) -> Void)?
    var onHome: ((UUID) -> Void)?
    var onSelectSpace: ((UUID) -> Void)?
    var onShowAll: (() -> Void)?
    var onMouseExit: (() -> Void)?

    static let height: CGFloat = 170
    private let spaceColumn = NSStackView()
    private var cardViews: [TabCardView] = []
    private let divider = NSBox()
    private let allTile = NSButton()
    private var pinnedCount = 0
    private var liftAccumulator: CGFloat = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        material = .popover
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 16
        spaceColumn.orientation = .vertical
        spaceColumn.alignment = .leading
        spaceColumn.spacing = 2
        divider.boxType = .separator
        allTile.title = "Tout voir"
        allTile.image = NSImage(systemSymbolName: "square.grid.3x3", accessibilityDescription: nil)
        allTile.imagePosition = .imageAbove
        allTile.bezelStyle = .regularSquare
        allTile.isBordered = false
        allTile.wantsLayer = true
        allTile.layer?.cornerRadius = 10
        allTile.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        allTile.target = self
        allTile.action = #selector(showAll)
        allTile.toolTip = "Vue d'ensemble (Échap, ou tirer l'étagère vers le haut)"
        for view in [spaceColumn, divider, allTile] as [NSView] { addSubview(view) }
    }

    required init?(coder: NSCoder) { fatalError("non utilisé") }

    func update(spaces: [SpaceItem], pinned: [TabCard], recent: [TabCard]) {
        spaceColumn.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for space in spaces {
            let button = NSButton(title: "\(space.name)  \(space.count)", target: self, action: #selector(spaceClicked(_:)))
            button.isBordered = false
            button.image = Self.dot(space.color)
            button.imagePosition = .imageLeading
            button.font = .systemFont(ofSize: 12, weight: space.isCurrent ? .semibold : .regular)
            button.contentTintColor = space.isCurrent ? .labelColor : .secondaryLabelColor
            button.identifier = NSUserInterfaceItemIdentifier(space.id.uuidString)
            spaceColumn.addArrangedSubview(button)
        }
        cardViews.forEach { $0.removeFromSuperview() }
        pinnedCount = pinned.count
        cardViews = (pinned + recent).map { card in
            let view = TabCardView(card: card)
            view.onClick = { [weak self] in self?.onSelectTab?(card.id) }
            view.onHome = { [weak self] in self?.onHome?(card.id) }
            return view
        }
        cardViews.forEach(addSubview)
        divider.isHidden = pinned.isEmpty || recent.isEmpty
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let inset: CGFloat = 14, gap: CGFloat = 10
        spaceColumn.frame = NSRect(x: inset, y: inset, width: 130, height: bounds.height - 2 * inset)
        var x = spaceColumn.frame.maxX + 12
        let tileWidth: CGFloat = 90
        let available = bounds.width - x - tileWidth - inset - gap - (divider.isHidden ? 0 : 20)
        let cardHeight = bounds.height - 2 * inset
        let cardWidth = min(170, max(90, (available - gap * CGFloat(max(cardViews.count - 1, 0))) / CGFloat(max(cardViews.count, 1))))
        for (i, view) in cardViews.enumerated() {
            if i == pinnedCount, !divider.isHidden {
                divider.frame = NSRect(x: x + 4, y: inset, width: 1, height: cardHeight)
                x += 20
            }
            let fits = x + cardWidth <= bounds.width - tileWidth - inset - gap
            view.isHidden = !fits
            view.frame = NSRect(x: x, y: inset, width: cardWidth, height: cardHeight)
            if fits { x += cardWidth + gap }
        }
        allTile.frame = NSRect(x: bounds.width - tileWidth - inset, y: inset, width: tileWidth, height: cardHeight - TabCardView.captionHeight)
    }

    // MARK: Gestes

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseExited(with event: NSEvent) { onMouseExit?() }

    /// Tirer l'étagère vers le haut (deux doigts ou molette) ouvre la vue d'ensemble.
    override func scrollWheel(with event: NSEvent) {
        guard abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) else { return }
        let upward = event.isDirectionInvertedFromDevice ? -event.scrollingDeltaY : event.scrollingDeltaY
        liftAccumulator = max(0, liftAccumulator + upward)
        if event.phase == .ended || event.phase == .cancelled { liftAccumulator = 0 }
        if liftAccumulator > (event.hasPreciseScrollingDeltas ? 40 : 3) {
            liftAccumulator = 0
            onShowAll?()
        }
    }

    @objc private func showAll() { onShowAll?() }
    @objc private func spaceClicked(_ sender: NSButton) {
        if let id = sender.identifier.flatMap({ UUID(uuidString: $0.rawValue) }) { onSelectSpace?(id) }
    }

    static func dot(_ color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 8, height: 8), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect).fill()
            return true
        }
    }
}

/// Bande invisible contre le bord bas : la souris qui la touche fait monter l'étagère.
@MainActor
final class BottomEdgeZone: NSView {
    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { onEnter?() }
    override func mouseExited(with event: NSEvent) { onExit?() }
}
