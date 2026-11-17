import AppKit

/// Contenu d'un espace pour la Scène, préparé par la fenêtre : épinglés, onglets, puis archivés.
struct SceneContent {
    var pinned: [TabCard] = []
    var tabs: [TabCard] = []
    var archived: [TabCard] = []
    var all: [TabCard] { pinned + tabs + archived }
}

/// Vue d'ensemble « Scène » (D3, maquette `maquette/scene.html`).
///
/// La page recule sans disparaître ; la rangée des onglets de l'espace apparaît dessous ; les espaces sont sur un
/// rail à gauche. Même rangement que les transitions de page : onglets à l'horizontale (← →), espaces à la
/// verticale (↑ ↓). La page en grand sert d'aperçu : parcourir la rangée y montre l'onglet choisi, avant de l'ouvrir.
///
/// La page en grand est une **capture** (comme les vignettes) : l'aperçu est instantané et ne réveille pas les
/// onglets endormis qu'on ne fait que parcourir. La vraie page n'est affichée qu'à l'ouverture.
@MainActor
final class SceneView: FlippedView {
    struct SpaceInfo { var id: UUID; var name: String; var color: NSColor }

    // Données et actions fournies par la fenêtre.
    var contentProvider: ((UUID) -> SceneContent)?
    var onOpenTab: ((UUID) -> Void)?
    var onReopenArchived: ((UUID) -> Void)?
    /// L'espace montré a changé (↑ ↓, clic sur le rail) : il devient l'espace actif.
    var onShowSpace: ((UUID) -> Void)?
    /// Onglet glissé sur un autre espace du rail.
    var onMove: ((UUID, UUID) -> Void)?
    /// Échap : revenir à la page d'avant.
    var onDismiss: (() -> Void)?

    private(set) var spaces: [SpaceInfo] = []
    private(set) var shownSpaceID: UUID?
    private var content = SceneContent()
    private var cards: [TabCard] { content.all }
    private var selected = 0
    private var filter = ""
    /// Page affichée à l'ouverture : sa capture fraîche, pour y revenir avec Échap.
    private var originalTabID: UUID?
    private var originalImage: NSImage?

    /// Onglet choisi (⌘W, ⌘D visent celui-ci). Un archivé n'est pas un onglet ouvert.
    var focusedTabID: UUID? {
        guard cards.indices.contains(selected), !cards[selected].isArchived else { return nil }
        return cards[selected].id
    }

    private var rowSize: Int {
        get { UserDefaults.standard.object(forKey: "VBSceneRowSize") as? Int ?? 1 }
        set { UserDefaults.standard.set(min(max(newValue, 0), 2), forKey: "VBSceneRowSize") }
    }
    private var geometry: SceneLayout { SceneLayout(bounds: bounds.size, size: rowSize) }

    // Calques et vues.
    private let house = CALayer()
    private let stage = CALayer()          // porte l'ombre
    private let stageClip = CALayer()      // coins arrondis, contient les captures
    private let rail = FlippedView()
    private var railEntries: [RailEntry] = []
    private let railMark = CALayer()
    private let hint = NSTextField(labelWithString: "")
    private let captionTitle = NSTextField(labelWithString: "")
    private let captionURL = NSTextField(labelWithString: "")
    private let sizeControl = SizeControl()
    private let rowScroll = NSScrollView()
    private let rowDocument = FlippedView()
    private var thumbs: [SceneThumbView] = []
    private var dividers: [NSView] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        isHidden = true
        house.backgroundColor = Design.Palette.house.cgColor
        house.opacity = 0
        layer?.addSublayer(house)

        stage.shadowColor = NSColor.black.cgColor
        stage.shadowOpacity = 0
        stage.shadowRadius = 30
        stage.shadowOffset = CGSize(width: 0, height: -18)
        stageClip.masksToBounds = true
        stageClip.backgroundColor = NSColor(white: 0.16, alpha: 1).cgColor
        stage.addSublayer(stageClip)
        layer?.addSublayer(stage)

        rail.wantsLayer = true
        railMark.cornerRadius = 1.5
        rail.layer?.addSublayer(railMark)
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = Design.Palette.paper(.tertiary)
        hint.maximumNumberOfLines = 3
        hint.attributedStringValue = Self.hintText()
        rail.addSubview(hint)

        captionTitle.font = Design.Typography.bodyStrong
        captionTitle.textColor = Design.Palette.paper
        captionTitle.lineBreakMode = .byTruncatingTail
        captionURL.lineBreakMode = .byTruncatingMiddle
        captionURL.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        sizeControl.onChange = { [weak self] size in self?.setRowSize(size) }

        rowScroll.drawsBackground = false
        rowScroll.hasHorizontalScroller = false
        rowScroll.hasVerticalScroller = false
        rowScroll.documentView = rowDocument
        rowScroll.contentView.drawsBackground = false

        for view in [rail, captionTitle, captionURL, sizeControl, rowScroll] as [NSView] { addSubview(view) }
    }

    required init?(coder: NSCoder) { fatalError("non utilisé") }

    override var acceptsFirstResponder: Bool { true }

    // MARK: Ouverture et fermeture

    /// Ouvre la Scène sur un espace : la page (sa capture) recule jusqu'à sa place, la rangée et le rail apparaissent.
    func present(spaces: [SpaceInfo], showing spaceID: UUID, activeTabID: UUID?, pageImage: NSImage?) {
        self.spaces = spaces
        shownSpaceID = spaceID
        filter = ""
        originalTabID = activeTabID
        originalImage = pageImage
        isHidden = false
        alphaValue = 1
        window?.makeFirstResponder(self)
        reload()
        selected = cards.firstIndex { $0.id == activeTabID } ?? 0
        layoutScene()
        updateSelection(animated: false)

        // Point de départ : la capture couvre toute la fenêtre, rien d'autre n'est visible.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        setStageImage(pageImage ?? cards.first?.image, transition: nil)
        stage.frame = bounds
        stageClip.frame = stage.bounds
        stageClip.cornerRadius = 0
        stage.shadowOpacity = 0
        house.frame = bounds
        house.opacity = 0
        CATransaction.commit()
        for view in [rail, captionTitle, captionURL, sizeControl, rowScroll] as [NSView] { view.alphaValue = 0 }

        // La page recule, la salle s'éteint autour, puis rail, rangée et légende arrivent.
        let move = Design.Motion.allowsMovement()
        animateLayers(.slow) {
            self.house.opacity = 1
            self.placeStage(self.geometry.stage, radius: Design.Shape.stageRadius, shadow: 0.45)
        }
        if !move { layoutScene() }
        let rowFrame = rowScroll.frame
        if move { rowScroll.frame = rowFrame.offsetBy(dx: 0, dy: 24) }
        Design.Motion.animate(.slow) {
            self.rowScroll.animator().alphaValue = 1
            self.rowScroll.animator().frame = rowFrame
            self.rail.animator().alphaValue = 1
            for view in [self.captionTitle, self.captionURL, self.sizeControl] as [NSView] { view.animator().alphaValue = 1 }
        }
    }

    /// Ferme la Scène : la page choisie (sa capture) revient au premier plan, puis la vraie page prend le relais.
    func dismiss(expanding cardID: UUID?, completion: @escaping () -> Void) {
        let image = cardID == originalTabID ? (originalImage ?? image(of: cardID)) : image(of: cardID)
        if let image, stageClip.sublayers?.last?.contents as? NSImage !== image { setStageImage(image, transition: nil) }
        Design.Motion.animate(.fast) {
            for view in [self.rail, self.captionTitle, self.captionURL, self.sizeControl, self.rowScroll] as [NSView] {
                view.animator().alphaValue = 0
            }
        }
        animateLayers(.slow, {
            self.placeStage(self.bounds, radius: 0, shadow: 0)
            self.house.opacity = 0
        }, completion: { [weak self] in
            self?.isHidden = true
            completion()
        })
    }

    // MARK: Contenu

    /// Recharge l'espace montré (onglet fermé, épinglé, déplacé…) en gardant la sélection si possible.
    func reload() {
        guard let shownSpaceID else { return }
        let keep = cards.indices.contains(selected) ? cards[selected].id : nil
        content = contentProvider?(shownSpaceID) ?? SceneContent()
        selected = cards.firstIndex { $0.id == keep } ?? min(selected, max(cards.count - 1, 0))
        buildRail()
        buildRow()
        layoutScene()
        updateSelection(animated: false)
        if !isHidden, cards.indices.contains(selected), keep != cards[selected].id { setStageImage(cards[selected].image, transition: nil) }
    }

    /// Montre un autre espace : la rangée et la page glissent à la verticale, comme le rail.
    func show(space id: UUID) {
        guard id != shownSpaceID, let to = spaces.firstIndex(where: { $0.id == id }) else { return }
        let from = spaces.firstIndex { $0.id == shownSpaceID } ?? to
        let direction: CGFloat = to > from ? 1 : -1
        shownSpaceID = id
        content = contentProvider?(id) ?? SceneContent()
        selected = cards.firstIndex(where: \.isActive) ?? 0
        buildRail()
        buildRow()
        layoutScene()
        updateSelection(animated: false)
        setStageImage(cards.indices.contains(selected) ? cards[selected].image : nil, transition: (0, direction * 48))
        guard Design.Motion.allowsMovement() else { return }
        let rowFrame = rowScroll.frame
        rowScroll.frame = rowFrame.offsetBy(dx: 0, dy: direction * 20)
        rowScroll.alphaValue = 0
        Design.Motion.animate(.medium) {
            self.rowScroll.animator().frame = rowFrame
            self.rowScroll.animator().alphaValue = 1
        }
    }

    private func goSpace(by step: Int) {
        guard let current = spaces.firstIndex(where: { $0.id == shownSpaceID }) else { return }
        let next = SceneLayout.step(current, by: step, count: spaces.count)
        guard next != current else { return }
        onShowSpace?(spaces[next].id)
        show(space: spaces[next].id)
    }

    private func image(of id: UUID?) -> NSImage? { cards.first { $0.id == id }?.image }

    // MARK: Sélection

    /// Choisir un onglet de la rangée : la page en grand le montre aussitôt.
    private func select(_ index: Int) {
        guard cards.indices.contains(index), index != selected else { return }
        let direction: CGFloat = index > selected ? 1 : -1
        selected = index
        updateSelection(animated: true)
        setStageImage(cards[index].image, transition: (direction * 28, 0))
    }

    private func updateSelection(animated: Bool) {
        let rowLayout = geometry
        let place: @MainActor @Sendable () -> Void = {
            for (index, thumb) in self.thumbs.enumerated() {
                thumb.isSelected = index == self.selected
                let frame = self.thumbFrame(at: index, layout: rowLayout)
                (animated ? thumb.animator() : thumb).frame = frame
                (animated ? thumb.animator() : thumb).alphaValue = thumb.targetAlpha
            }
        }
        if animated { Design.Motion.animate(.fast, place) } else { place() }
        if thumbs.indices.contains(selected) {
            rowDocument.scrollToVisible(thumbs[selected].frame.insetBy(dx: -60, dy: 0))
        }
        updateCaption()
    }

    private func updateCaption() {
        guard cards.indices.contains(selected) else {
            captionTitle.stringValue = cards.isEmpty ? (filter.isEmpty ? "Espace vide" : "Aucun onglet pour « \(filter) »") : ""
            captionURL.stringValue = ""
            return
        }
        let card = cards[selected]
        captionTitle.stringValue = (card.isArchived ? "Archivé · " : "") + card.title
        let host = card.host, rest = card.url.map { url -> String in
            var text = url.path(percentEncoded: false)
            if let query = url.query(percentEncoded: false) { text += "?" + query }
            if let fragment = url.fragment(percentEncoded: false) { text += "#" + fragment }
            return text == "/" ? "" : text
        } ?? ""
        let url = NSMutableAttributedString(string: host, attributes: [.font: Design.Typography.small, .foregroundColor: Design.Palette.paper])
        url.append(NSAttributedString(string: rest, attributes: [.font: Design.Typography.small, .foregroundColor: Design.Palette.paper(.secondary)]))
        captionURL.attributedStringValue = url
        layoutCaption()
    }

    /// Titre à sa largeur naturelle (au plus 55 % de la légende), l'adresse prend le reste.
    private func layoutCaption() {
        let caption = geometry.caption, sizeWidth: CGFloat = 60
        captionTitle.sizeToFit()
        let titleWidth = min(captionTitle.frame.width, caption.width * 0.55)
        captionTitle.frame = NSRect(x: caption.minX, y: caption.minY, width: titleWidth, height: 20)
        captionURL.frame = NSRect(x: caption.minX + titleWidth + 14, y: caption.minY + 2,
                                  width: max(caption.width - titleWidth - 14 - sizeWidth - 12, 40), height: 18)
        sizeControl.frame = NSRect(x: caption.maxX - sizeWidth, y: caption.minY + 3, width: sizeWidth, height: 14)
    }

    /// Change la capture montrée en grand. `transition` : décalage d'entrée de la nouvelle (x, y), nil = sans animation.
    private func setStageImage(_ image: NSImage?, transition: (CGFloat, CGFloat)?) {
        let shot = CALayer()
        shot.contents = image
        shot.contentsGravity = .resizeAspectFill
        shot.frame = stageClip.bounds
        shot.backgroundColor = image == nil ? NSColor(white: 0.16, alpha: 1).cgColor : nil
        let old = stageClip.sublayers ?? []
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        stageClip.addSublayer(shot)
        CATransaction.commit()
        guard let transition else { old.forEach { $0.removeFromSuperlayer() }; return }
        let duration = Design.Motion.duration(transition.1 == 0 ? .medium : .slow)
        let group = CAAnimationGroup()
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        var animations: [CAAnimation] = [fade]
        if Design.Motion.allowsMovement() {
            let move = CABasicAnimation(keyPath: "transform")
            move.fromValue = CATransform3DMakeTranslation(transition.0, transition.1, 0)
            move.toValue = CATransform3DIdentity
            animations.append(move)
        }
        group.animations = animations
        group.duration = duration
        group.timingFunction = Design.Motion.curve
        CATransaction.begin()
        CATransaction.setCompletionBlock { MainActor.assumeIsolated { old.forEach { $0.removeFromSuperlayer() } } }
        shot.add(group, forKey: "vision.stage")
        CATransaction.commit()
    }

    private func placeStage(_ frame: CGRect, radius: CGFloat, shadow: Float) {
        stage.frame = frame
        stageClip.frame = stage.bounds
        stageClip.cornerRadius = radius
        stageClip.sublayers?.forEach { $0.frame = stageClip.bounds }
        stage.shadowOpacity = shadow
    }

    private func animateLayers(_ speed: Design.Motion.Speed, _ changes: () -> Void, completion: (@MainActor () -> Void)? = nil) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(Design.Motion.duration(speed))
        CATransaction.setAnimationTimingFunction(Design.Motion.curve)
        if let completion { CATransaction.setCompletionBlock { MainActor.assumeIsolated { completion() } } }
        changes()
        CATransaction.commit()
    }

    // MARK: Construction

    private func buildRail() {
        railEntries.forEach { $0.removeFromSuperview() }
        railEntries = spaces.map { space in
            let count = (contentProvider?(space.id) ?? SceneContent()).all.filter { matches($0) && !$0.isArchived }.count
            let entry = RailEntry(space: space, count: count, isCurrent: space.id == shownSpaceID)
            entry.onClick = { [weak self] in
                guard let self, space.id != self.shownSpaceID else { return }
                self.onShowSpace?(space.id)
                self.show(space: space.id)
            }
            entry.onDropTab = { [weak self] tabID in self?.onMove?(tabID, space.id) }
            rail.addSubview(entry)
            return entry
        }
    }

    private func buildRow() {
        thumbs.forEach { $0.removeFromSuperview() }
        dividers.forEach { $0.removeFromSuperview() }
        dividers = []
        thumbs = cards.enumerated().map { index, card in
            let thumb = SceneThumbView(card: card)
            thumb.isDimmed = !matches(card)
            thumb.onHover = { [weak self] in self?.select(index) }
            thumb.onClick = { [weak self] in
                self?.select(index)
                self?.openSelected()
            }
            rowDocument.addSubview(thumb)
            return thumb
        }
        for _ in 0..<2 {
            let divider = NSView()
            divider.wantsLayer = true
            divider.layer?.backgroundColor = Design.Palette.paper(.tertiary).cgColor
            rowDocument.addSubview(divider)
            dividers.append(divider)
        }
    }

    override func layout() {
        super.layout()
        layoutScene()
    }

    private func layoutScene() {
        let l = geometry
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        house.frame = bounds
        if !isHidden, stage.animationKeys() == nil, stage.frame != .zero, stage.frame != bounds { placeStage(l.stage, radius: Design.Shape.stageRadius, shadow: 0.45) }
        CATransaction.commit()

        rail.frame = l.rail
        for (index, entry) in railEntries.enumerated() {
            entry.frame = NSRect(x: 36, y: SceneLayout.margin + CGFloat(index) * 34, width: SceneLayout.railWidth - 52, height: 30)
        }
        if let current = spaces.firstIndex(where: { $0.id == shownSpaceID }) {
            railMark.backgroundColor = spaces[current].color.cgColor
            railMark.frame = CGRect(x: 20, y: SceneLayout.margin + CGFloat(current) * 34, width: 3, height: 30)
        }
        hint.frame = NSRect(x: 36, y: bounds.height - SceneLayout.margin - 52, width: SceneLayout.railWidth - 40, height: 52)

        layoutCaption()
        sizeControl.size = rowSize

        rowScroll.frame = l.row
        var x: CGFloat = 0
        for (index, thumb) in thumbs.enumerated() {
            if index > 0, needsDivider(before: index) {
                let divider = dividers[cards[index].isArchived ? 1 : 0]
                divider.frame = NSRect(x: x + 4, y: 12, width: 1, height: l.thumbSize.height)
                x += 25
            }
            thumb.frame = thumbFrame(at: index, layout: l, x: x)
            thumb.originX = x
            x += l.thumbSize.width + 16
        }
        dividers.enumerated().forEach { i, d in d.isHidden = !thumbs.indices.contains(where: { $0 > 0 && needsDivider(before: $0) && (cards[$0].isArchived ? 1 : 0) == i }) }
        rowDocument.frame = NSRect(x: 0, y: 0, width: max(x + SceneLayout.margin, rowScroll.bounds.width), height: l.row.height)
    }

    private func needsDivider(before index: Int) -> Bool {
        let previous = cards[index - 1], card = cards[index]
        return (previous.isPinned && !card.isPinned) || (!previous.isArchived && card.isArchived)
    }

    private func thumbFrame(at index: Int, layout l: SceneLayout, x: CGFloat? = nil) -> NSRect {
        let originX = x ?? thumbs[index].originX
        let lift: CGFloat = index == selected ? 0 : 8
        return NSRect(x: originX, y: lift, width: l.thumbSize.width, height: l.thumbSize.height + SceneLayout.nameHeight)
    }

    private func setRowSize(_ size: Int) {
        guard size != rowSize else { return }
        rowSize = size
        animateLayers(.medium) { self.placeStage(self.geometry.stage, radius: Design.Shape.stageRadius, shadow: 0.45) }
        layoutScene()
        updateSelection(animated: false)
    }

    private func matches(_ card: TabCard) -> Bool { TabOrganizer.matches(title: card.title, url: card.url, filter: filter) }

    private func applyFilter() {
        for (thumb, card) in zip(thumbs, cards) { thumb.isDimmed = !matches(card) }
        if cards.indices.contains(selected), !matches(cards[selected]), let first = cards.firstIndex(where: matches) { select(first) }
        buildRail()
        layoutScene()
        updateSelection(animated: false)
        hint.attributedStringValue = filter.isEmpty ? Self.hintText() : Self.filterText(filter)
    }

    private func openSelected() {
        guard cards.indices.contains(selected) else { return }
        let card = cards[selected]
        card.isArchived ? onReopenArchived?(card.id) : onOpenTab?(card.id)
    }

    // MARK: Clavier

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if flags.contains(.command) || flags.contains(.control) { return super.keyDown(with: event) }
        switch event.keyCode {
        case 53: handleEscape()
        case 36, 76: openSelected()
        case 51: if !filter.isEmpty { filter.removeLast(); applyFilter() }
        case 123: select(SceneLayout.step(selected, by: -1, count: cards.count))
        case 124: select(SceneLayout.step(selected, by: 1, count: cards.count))
        case 126: goSpace(by: -1)
        case 125: goSpace(by: 1)
        default:
            guard let text = event.characters, !text.isEmpty else { return super.keyDown(with: event) }
            if filter.isEmpty, text == "+" || text == "=" { return setRowSize(rowSize + 1) }
            if filter.isEmpty, text == "-" { return setRowSize(rowSize - 1) }
            guard text.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }), text != " " || !filter.isEmpty else {
                return super.keyDown(with: event)
            }
            filter += text
            applyFilter()
        }
    }

    /// Échap (reçu ici ou par la fenêtre) : efface le filtre, sinon revient à la page d'avant.
    func handleEscape() {
        if filter.isEmpty { onDismiss?() } else { filter = ""; applyFilter() }
    }

    private static func hintText() -> NSAttributedString {
        let text = NSMutableAttributedString()
        let key: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: Design.Palette.paper(.secondary)]
        let plain: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: Design.Palette.paper(.tertiary)]
        for (keys, label) in [("↑ ↓", " espaces\n"), ("← →", " onglets\n"), ("↩", " ouvrir · ")] {
            text.append(NSAttributedString(string: keys, attributes: key))
            text.append(NSAttributedString(string: label, attributes: plain))
        }
        text.append(NSAttributedString(string: "Échap", attributes: key))
        text.append(NSAttributedString(string: " revenir", attributes: plain))
        return text
    }

    private static func filterText(_ filter: String) -> NSAttributedString {
        let text = NSMutableAttributedString(string: "Filtre ", attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: Design.Palette.paper(.tertiary)])
        text.append(NSAttributedString(string: filter, attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: Design.Palette.paper]))
        text.append(NSAttributedString(string: "\nÉchap pour effacer", attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: Design.Palette.paper(.tertiary)]))
        return text
    }
}

// MARK: - Vignette de la rangée

/// Une vignette : capture de l'onglet et son nom. La vignette choisie est montée et pleinement visible,
/// les autres en retrait ; celles qui ne correspondent pas au filtre presque effacées.
@MainActor
final class SceneThumbView: FlippedView, NSDraggingSource {
    let card: TabCard
    var onHover: (() -> Void)?
    var onClick: (() -> Void)?
    var originX: CGFloat = 0
    var isSelected = false { didSet { updateStyle() } }
    var isDimmed = false { didSet { updateStyle() } }
    var targetAlpha: CGFloat { isDimmed ? 0.12 : (isSelected ? 1 : (card.isArchived ? 0.35 : 0.5)) }

    private let image = CALayer()
    private let current = CALayer()
    private let name = NSTextField(labelWithString: "")
    private var mouseDownPoint: NSPoint?

    init(card: TabCard) {
        self.card = card
        super.init(frame: .zero)
        wantsLayer = true
        image.contents = card.image
        image.contentsGravity = .resizeAspectFill
        image.masksToBounds = true
        image.cornerRadius = Design.Shape.thumbRadius
        image.backgroundColor = NSColor(white: 0.2, alpha: 1).cgColor
        layer?.addSublayer(image)
        current.backgroundColor = Design.Palette.paper.cgColor
        current.cornerRadius = 1.5
        current.isHidden = !card.isActive
        image.addSublayer(current)
        let prefix = card.isPinned ? "Épinglé · " : (card.isArchived ? "Archivé · " : "")
        name.stringValue = prefix + card.title
        name.font = .systemFont(ofSize: 11)
        name.lineBreakMode = .byTruncatingTail
        addSubview(name)
        updateStyle()
    }

    required init?(coder: NSCoder) { fatalError("non utilisé") }

    override func layout() {
        super.layout()
        let height = bounds.height - SceneLayout.nameHeight
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        image.frame = CGRect(x: 0, y: 0, width: bounds.width, height: height)
        current.frame = CGRect(x: bounds.width / 2 - 8, y: height - 9, width: 16, height: 3)
        CATransaction.commit()
        name.frame = NSRect(x: 0, y: height + 7, width: bounds.width, height: 16)
    }

    private func updateStyle() {
        name.textColor = isSelected ? Design.Palette.paper : Design.Palette.paper(.secondary)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { onHover?() }
    override func mouseDown(with event: NSEvent) { mouseDownPoint = event.locationInWindow }
    override func mouseUp(with event: NSEvent) {
        defer { mouseDownPoint = nil }
        if mouseDownPoint != nil { onClick?() }
    }

    /// Glisser une vignette sur un espace du rail l'y déplace.
    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownPoint, !card.isArchived,
              hypot(event.locationInWindow.x - start.x, event.locationInWindow.y - start.y) > 4 else { return }
        mouseDownPoint = nil
        let item = NSPasteboardItem()
        item.setString(card.id.uuidString, forType: .visionTab)
        let dragging = NSDraggingItem(pasteboardWriter: item)
        let snapshot = card.image ?? NSImage(size: image.frame.size)
        dragging.setDraggingFrame(image.frame, contents: snapshot)
        beginDraggingSession(with: [dragging], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }
}

// MARK: - Rail

/// Un espace du rail : son nom et son nombre d'onglets. Accepte une vignette déposée (déplacement vers cet espace).
@MainActor
private final class RailEntry: FlippedView {
    var onClick: (() -> Void)?
    var onDropTab: ((UUID) -> Void)?
    private let label = NSTextField(labelWithString: "")
    private let isCurrent: Bool
    private var dropping = false { didSet { updateStyle() } }

    init(space: SceneView.SpaceInfo, count: Int, isCurrent: Bool) {
        self.isCurrent = isCurrent
        super.init(frame: .zero)
        let text = NSMutableAttributedString(string: space.name, attributes: [
            .font: isCurrent ? Design.Typography.bodyStrong : Design.Typography.body])
        text.append(NSAttributedString(string: "  \(count)", attributes: [.font: Design.Typography.small, .foregroundColor: Design.Palette.paper(.tertiary)]))
        label.attributedStringValue = text
        addSubview(label)
        registerForDraggedTypes([.visionTab])
        updateStyle()
    }

    required init?(coder: NSCoder) { fatalError("non utilisé") }

    override func layout() {
        super.layout()
        label.frame = NSRect(x: 0, y: (bounds.height - 18) / 2, width: bounds.width, height: 18)
    }

    private func updateStyle() {
        label.textColor = isCurrent || dropping ? Design.Palette.paper : Design.Palette.paper(.tertiary)
        let text = NSMutableAttributedString(attributedString: label.attributedStringValue)
        let nameLength = (text.string as NSString).range(of: "  ").location
        if nameLength != NSNotFound {
            text.addAttribute(.foregroundColor, value: label.textColor ?? Design.Palette.paper, range: NSRange(location: 0, length: nameLength))
            label.attributedStringValue = text
        }
    }

    override func mouseUp(with event: NSEvent) { onClick?() }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard !isCurrent else { return [] }
        dropping = true
        return .move
    }
    override func draggingExited(_ sender: (any NSDraggingInfo)?) { dropping = false }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        dropping = false
        guard !isCurrent, let raw = sender.draggingPasteboard.string(forType: .visionTab), let id = UUID(uuidString: raw) else { return false }
        // Laisser la session de glisser se terminer avant de recharger la rangée (qui retire la vignette glissée).
        perform(#selector(deliverDrop(_:)), with: id.uuidString, afterDelay: 0)
        return true
    }
    @objc private func deliverDrop(_ raw: String) { if let id = UUID(uuidString: raw) { onDropTab?(id) } }
}

// MARK: - Taille de la rangée

/// Trois petits rectangles de taille croissante : petites, moyennes, grandes vignettes.
@MainActor
private final class SizeControl: FlippedView {
    var onChange: ((Int) -> Void)?
    var size = 1 { didSet { needsDisplay = true } }
    private let sizes: [CGSize] = [CGSize(width: 12, height: 8), CGSize(width: 15, height: 10), CGSize(width: 19, height: 12)]

    private func rects() -> [NSRect] {
        var x = bounds.width - sizes.reduce(0) { $0 + $1.width } - 12
        return sizes.map { s in
            defer { x += s.width + 6 }
            return NSRect(x: x, y: bounds.height - s.height, width: s.width, height: s.height)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        for (index, rect) in rects().enumerated() {
            (index == size ? Design.Palette.paper : Design.Palette.paper(.tertiary)).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill()
        }
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let index = rects().firstIndex(where: { $0.insetBy(dx: -3, dy: -4).contains(point) }) { onChange?(index) }
    }
}
