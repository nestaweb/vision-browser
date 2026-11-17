import AppKit

/// La barre `Cmd+T` (F4, direction « Scène », maquette `maquette/scene.html`).
///
/// Au centre, minimaliste : une feuille claire, une seule ombre, du texte. La ligne choisie s'inverse
/// (papier sur encre) et le bloc glisse d'une ligne à l'autre.
///
/// Ouverture « la fente » : un trait naît au centre de la barre et s'étire, s'ouvre en hauteur pour devenir le
/// champ, puis la liste se déroule. Fermeture : l'inverse. Le tout par un masque sur la feuille ; l'ombre suit.
@MainActor
final class CommandBarView: NSView, NSTextFieldDelegate {
    let field = NSTextField()

    private(set) var results: [CommandResult] = []
    private(set) var isNewTab = false
    /// Ouverte au sens logique : vrai dès l'ouverture, faux dès la fermeture, même pendant l'animation.
    /// (La fenêtre doit se fier à cet état, pas à `isHidden`, qui ne change qu'à la fin de la fente.)
    private(set) var isOpen = false
    var query: String { field.stringValue }

    /// Façon de valider le résultat choisi.
    enum Submit {
        /// Entrée : action normale (ouvrir, basculer, remplir…).
        case normal
        /// Cmd+Entrée : l'autre onglet (onglet actuel depuis Cmd+T, nouvel onglet depuis Cmd+L).
        case otherTab
        /// Option+Entrée : copier (mot de passe Bitwarden, élément du presse-papier, adresse).
        case copy
    }

    var onQueryChange: ((String) -> Void)?
    var onExecute: ((CommandResult?, _ typed: String, _ mode: Submit) -> Void)?
    var onCancel: (() -> Void)?
    /// ⇧← / ⇧→ quand rien n'est tapé : espace précédent / suivant (sinon on resterait bloqué dans un espace vide).
    var onStepSpace: ((Int) -> Void)?

    static let fieldHeight: CGFloat = 56
    static let rowHeight: CGFloat = 40
    private static let listInset: CGFloat = 6
    private static let footerHeight: CGFloat = 34

    private let sheet = FlippedView()
    private let space = NSTextField(labelWithString: "")
    private let topRule = NSView()
    private let bottomRule = NSView()
    private let highlight = NSView()
    private var rows: [ResultRow] = []
    private let footer = NSTextField(labelWithString: "")
    private var selected = 0
    private var height: NSLayoutConstraint!
    /// Numéro de la dernière animation lancée : une animation dépassée (barre rouverte entre-temps) ne fait rien.
    private var animationToken = 0

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.2
        layer?.shadowRadius = 22
        layer?.shadowOffset = CGSize(width: 0, height: -14)

        sheet.wantsLayer = true
        sheet.layer?.backgroundColor = Design.Palette.sheet.cgColor
        sheet.layer?.cornerRadius = Design.Shape.barRadius
        sheet.layer?.masksToBounds = true
        sheet.layer?.borderWidth = 0.5
        sheet.layer?.borderColor = Design.Palette.ink.withAlphaComponent(0.16).cgColor
        addSubview(sheet)

        field.font = Design.Typography.field
        field.textColor = Design.Palette.ink
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.placeholderAttributedString = NSAttributedString(string: "Adresse, recherche ou commande", attributes: [
            .font: Design.Typography.field, .foregroundColor: Design.Palette.ink(.tertiary)])
        field.delegate = self
        field.cell?.usesSingleLineMode = true
        field.cell?.isScrollable = true

        space.font = Design.Typography.small
        space.textColor = Design.Palette.ink(.secondary)
        space.alignment = .right

        for rule in [topRule, bottomRule] {
            rule.wantsLayer = true
            rule.layer?.backgroundColor = Design.Palette.rule.cgColor
        }
        highlight.wantsLayer = true
        highlight.layer?.backgroundColor = Design.Palette.ink.cgColor
        highlight.layer?.cornerRadius = Design.Shape.rowRadius

        footer.font = .systemFont(ofSize: 11)
        footer.textColor = Design.Palette.ink(.tertiary)

        for view in [field, space, topRule, highlight, bottomRule, footer] as [NSView] { sheet.addSubview(view) }
        isHidden = true
        height = heightAnchor.constraint(equalToConstant: Self.fieldHeight)
        height.isActive = true
    }

    required init?(coder: NSCoder) { fatalError("non utilisé") }

    // MARK: Ouverture et fermeture

    /// - Parameter spaceName: l'espace où s'ouvrira la page, rappelé à droite du champ.
    func present(text: String, newTab: Bool, spaceName: String) {
        isNewTab = newTab
        field.stringValue = text
        space.stringValue = spaceName
        footer.attributedStringValue = Self.footerText(newTab: newTab)
        let wasOpen = isOpen
        isOpen = true
        isHidden = false
        field.selectText(nil)
        if !wasOpen { playOpening() }
    }

    /// Referme la barre par la fente, puis la masque.
    func dismiss() {
        guard isOpen else { return }
        isOpen = false
        animationToken += 1
        let token = animationToken
        guard Design.Motion.allowsMovement() else {
            Design.Motion.animate(.fast, { self.animator().alphaValue = 0 }) { [weak self] in
                guard let self, self.animationToken == token else { return }
                self.isHidden = true
                self.alphaValue = 1
            }
            return
        }
        let (width, full) = (sheet.bounds.width, sheet.bounds.height)
        let mask = installMask(CGRect(x: 0, y: 0, width: width, height: full))
        let line = Self.lineRect(width: width)
        // La liste remonte, la barre se pince en trait, le trait se rétracte en un point.
        animateMask(mask, to: CGRect(x: 0, y: 0, width: width, height: Self.fieldHeight), .fast, token: token, skipIf: full <= Self.fieldHeight + 1) {
            self.animateMask(mask, to: line, .fast, token: token) {
                self.animateMask(mask, to: CGRect(x: width / 2, y: line.minY, width: 0, height: line.height), .fast, token: token) {
                    self.isHidden = true
                    self.sheet.layer?.mask = nil
                }
            }
        }
    }

    /// Un trait naît au centre et s'étire, s'ouvre en hauteur (le champ), puis la liste se déroule.
    private func playOpening() {
        animationToken += 1
        let token = animationToken
        alphaValue = 1
        superview?.layoutSubtreeIfNeeded()
        layoutSubtreeIfNeeded()
        guard Design.Motion.allowsMovement() else {
            sheet.layer?.mask = nil
            alphaValue = 0
            Design.Motion.animate(.medium) { self.animator().alphaValue = 1 }
            return
        }
        let width = sheet.bounds.width
        let line = Self.lineRect(width: width)
        let mask = installMask(CGRect(x: width / 2, y: line.minY, width: 0, height: line.height))
        animateMask(mask, to: line, .fast, token: token) {
            self.animateMask(mask, to: CGRect(x: 0, y: 0, width: width, height: Self.fieldHeight), .medium, token: token) {
                // La liste a pu changer pendant l'ouverture : on la déroule jusqu'à la hauteur du moment.
                self.animateMask(mask, to: CGRect(x: 0, y: 0, width: width, height: self.sheet.bounds.height), .medium, token: token) {
                    self.sheet.layer?.mask = nil
                }
            }
        }
    }

    /// Le trait de la fente : 2 pt au milieu du champ.
    private static func lineRect(width: CGFloat) -> CGRect {
        CGRect(x: 0, y: fieldHeight / 2 - 1, width: width, height: 2)
    }

    private func installMask(_ frame: CGRect) -> CALayer {
        let mask = CALayer()
        mask.backgroundColor = NSColor.black.cgColor
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mask.frame = frame
        sheet.layer?.mask = mask
        CATransaction.commit()
        return mask
    }

    private func animateMask(_ mask: CALayer, to frame: CGRect, _ speed: Design.Motion.Speed, token: Int,
                             skipIf skip: Bool = false, then next: @escaping @MainActor () -> Void) {
        guard animationToken == token else { return }
        if skip { return next() }
        CATransaction.begin()
        CATransaction.setAnimationDuration(Design.Motion.duration(speed))
        CATransaction.setAnimationTimingFunction(Design.Motion.curve)
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.animationToken == token else { return }
                next()
            }
        }
        mask.frame = frame
        CATransaction.commit()
    }

    // MARK: Résultats

    /// Affiche de nouveaux résultats. `keepSelection` : vrai quand des suggestions arrivent après coup.
    func show(results newResults: [CommandResult], keepSelection: Bool = false) {
        let previous = keepSelection ? selected : 0
        results = newResults
        rows.forEach { $0.removeFromSuperview() }
        rows = newResults.enumerated().map { index, result in
            let row = ResultRow(result: result)
            row.onHover = { [weak self] in self?.select(index, animated: true) }
            row.onClick = { [weak self] in
                guard let self else { return }
                self.select(index, animated: false)
                self.onExecute?(result, self.query, .normal)
            }
            sheet.addSubview(row)
            return row
        }
        selected = min(max(previous, 0), max(results.count - 1, 0))
        let listHeight = results.isEmpty ? 0 : 1 + Self.listInset * 2 + CGFloat(results.count) * Self.rowHeight + 1 + Self.footerHeight
        height.constant = Self.fieldHeight + listHeight
        superview?.layoutSubtreeIfNeeded()
        layoutSheet()
        select(selected, animated: false, force: true)
    }

    private func select(_ index: Int, animated: Bool, force: Bool = false) {
        guard results.indices.contains(index), force || index != selected else { return }
        selected = index
        for (i, row) in rows.enumerated() { row.isChosen = i == index }
        let frame = rowFrame(index)
        highlight.isHidden = false
        if animated { Design.Motion.animate(.fast) { self.highlight.animator().frame = frame } }
        else { highlight.frame = frame }
    }

    private func rowFrame(_ index: Int) -> NSRect {
        NSRect(x: Self.listInset, y: Self.fieldHeight + 1 + Self.listInset + CGFloat(index) * Self.rowHeight,
               width: sheet.bounds.width - Self.listInset * 2, height: Self.rowHeight)
    }

    override func layout() {
        super.layout()
        layoutSheet()
    }

    private func layoutSheet() {
        sheet.frame = bounds
        let width = bounds.width
        space.sizeToFit()
        let spaceWidth = min(space.frame.width, 160)
        space.frame = NSRect(x: width - 18 - spaceWidth, y: (Self.fieldHeight - 16) / 2, width: spaceWidth, height: 16)
        field.frame = NSRect(x: 18, y: (Self.fieldHeight - 26) / 2, width: width - 36 - spaceWidth - 12, height: 26)
        let hasList = !results.isEmpty
        topRule.isHidden = !hasList
        bottomRule.isHidden = !hasList
        footer.isHidden = !hasList
        highlight.isHidden = !hasList
        topRule.frame = NSRect(x: 0, y: Self.fieldHeight, width: width, height: 1)
        for (index, row) in rows.enumerated() { row.frame = rowFrame(index) }
        if hasList { highlight.frame = rowFrame(selected) }
        let footerTop = bounds.height - Self.footerHeight
        bottomRule.frame = NSRect(x: 0, y: footerTop - 1, width: width, height: 1)
        footer.frame = NSRect(x: 18, y: footerTop + 10, width: width - 36, height: 16)
    }

    private func submit(_ mode: Submit) {
        let chosen = results.indices.contains(selected) ? results[selected] : nil
        onExecute?(chosen, query, mode)
    }

    private static func footerText(newTab: Bool) -> NSAttributedString {
        let entries: [(String, String)] = newTab
            ? [("↩", "ouvrir"), ("⌘↩", "onglet actuel"), ("⌥↩", "copier"), ("Échap", "fermer")]
            : [("↩", "ouvrir ici"), ("⌘↩", "nouvel onglet"), ("⌥↩", "copier"), ("Échap", "fermer")]
        let text = NSMutableAttributedString()
        for (index, (key, label)) in entries.enumerated() {
            if index > 0 { text.append(NSAttributedString(string: "    ")) }
            text.append(NSAttributedString(string: key, attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                                                                     .foregroundColor: Design.Palette.ink(.secondary)]))
            text.append(NSAttributedString(string: " " + label, attributes: [.font: NSFont.systemFont(ofSize: 11),
                                                                             .foregroundColor: Design.Palette.ink(.tertiary)]))
        }
        return text
    }

    // MARK: Clavier

    func controlTextDidChange(_ notification: Notification) { onQueryChange?(query) }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            select(min(selected + 1, results.count - 1), animated: true); return true
        case #selector(NSResponder.moveUp(_:)):
            select(max(selected - 1, 0), animated: true); return true
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            // ⌥↩ arrive ici comme « insertNewlineIgnoringFieldEditor » : on lit la touche Option de l'événement.
            let option = NSApp.currentEvent?.modifierFlags.contains(.option) ?? false
            submit(option ? .copy : .normal); return true
        case #selector(NSResponder.cancelOperation(_:)):
            onCancel?(); return true
        case #selector(NSResponder.moveLeftAndModifySelection(_:)) where query.isEmpty:
            onStepSpace?(-1); return true
        case #selector(NSResponder.moveRightAndModifySelection(_:)) where query.isEmpty:
            onStepSpace?(1); return true
        default:
            return false
        }
    }

    /// Cmd+Entrée : un champ de texte ne le reçoit jamais comme « Entrée » (les combinaisons avec Cmd passent
    /// d'abord par les raccourcis). On l'intercepte donc ici, avant le champ.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard isOpen, flags == .command, event.keyCode == 36 || event.keyCode == 76 else { return super.performKeyEquivalent(with: event) }
        submit(.otherTab)
        return true
    }
}

// MARK: - Ligne de résultat

/// Une ligne : titre, puis à côté son adresse ou sa précision en plus discret ; à droite, sa nature
/// (« Ouvert · Pro A », « Bitwarden », « Historique »…) et, sur la ligne choisie, le verbe d'action.
/// Pas d'icône ni de couleur : la ligne choisie s'inverse.
@MainActor
private final class ResultRow: FlippedView {
    var onHover: (() -> Void)?
    var onClick: (() -> Void)?
    var isChosen = false { didSet { if isChosen != oldValue { restyle() } } }

    private let result: CommandResult
    private let label = NSTextField(labelWithString: "")
    private let meta = NSTextField(labelWithString: "")
    private let verb = NSTextField(labelWithString: "")

    init(result: CommandResult) {
        self.result = result
        super.init(frame: .zero)
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        meta.alignment = .right
        verb.alignment = .right
        for view in [label, meta, verb] { addSubview(view) }
        restyle()
    }

    required init?(coder: NSCoder) { fatalError("non utilisé") }

    override func layout() {
        super.layout()
        let verbWidth: CGFloat = isChosen ? 92 : 0
        meta.sizeToFit()
        let metaWidth = min(meta.frame.width, bounds.width * 0.35)
        verb.frame = NSRect(x: bounds.width - 12 - verbWidth, y: (bounds.height - 16) / 2, width: verbWidth, height: 16)
        meta.frame = NSRect(x: bounds.width - 12 - verbWidth - (verbWidth > 0 ? 10 : 0) - metaWidth, y: (bounds.height - 16) / 2,
                            width: metaWidth, height: 16)
        label.frame = NSRect(x: 12, y: (bounds.height - 18) / 2, width: meta.frame.minX - 12 - 16, height: 18)
    }

    private func restyle() {
        let ink = isChosen ? Design.Palette.paper : Design.Palette.ink
        let soft = isChosen ? Design.Palette.paper(.secondary) : Design.Palette.ink(.secondary)
        let text = NSMutableAttributedString(string: result.title, attributes: [
            .font: NSFont.systemFont(ofSize: Design.Typography.bodySize, weight: .medium), .foregroundColor: ink])
        if !result.subtitle.isEmpty {
            text.append(NSAttributedString(string: "   " + result.subtitle, attributes: [.font: Design.Typography.small, .foregroundColor: soft]))
        }
        label.attributedStringValue = text
        meta.attributedStringValue = NSAttributedString(string: Self.nature(of: result), attributes: [.font: Design.Typography.small, .foregroundColor: soft])
        verb.attributedStringValue = NSAttributedString(string: "\(result.actionLabel) ↩", attributes: [
            .font: NSFont.systemFont(ofSize: Design.Typography.smallSize, weight: .medium), .foregroundColor: ink])
        verb.isHidden = !isChosen
        needsLayout = true
    }

    /// Ce qu'est le résultat, en toutes lettres (remplace les pastilles et carrés de couleur).
    static func nature(of result: CommandResult) -> String {
        switch result.kind {
        case .openTab(_, let space): "Ouvert · \(space)"
        case .archived(_, let space): space.isEmpty ? "Archivé" : "Archivé · \(space)"
        case .bitwarden(_, let space): space.map { "Bitwarden · \($0)" } ?? "Bitwarden"
        case .clipboard(_, .secret, let bitwarden): bitwarden ? "Bitwarden · Touch ID" : "Masqué · Touch ID"
        case .clipboard: "Presse-papier"
        case .favorite: "Favori"
        case .history: result.isFavorite ? "Favori" : "Historique"
        case .address, .search, .suggestion, .command: ""
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { onHover?() }
    override func mouseUp(with event: NSEvent) { onClick?() }
}
