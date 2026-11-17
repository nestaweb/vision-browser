import AppKit

/// La barre `Cmd+T` : un champ et une liste de résultats, chaque type reconnaissable d'un coup d'œil (F4).
@MainActor
final class CommandBarView: NSVisualEffectView, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    let field = NSTextField()
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let separator = NSBox()
    private let footer = NSTextField(labelWithString: "")
    private var tableHeight: NSLayoutConstraint!

    private(set) var results: [CommandResult] = []
    private(set) var isNewTab = false
    var query: String { field.stringValue }

    var onQueryChange: ((String) -> Void)?
    /// Résultat choisi ; `invert` = Cmd+Entrée (inverse onglet courant / nouvel onglet).
    var onExecute: ((CommandResult?, _ typed: String, _ invert: Bool) -> Void)?
    var onCancel: (() -> Void)?

    static let rowHeight: CGFloat = 46

    init() {
        super.init(frame: .zero)
        material = .popover
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor

        field.font = .systemFont(ofSize: 20)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.placeholderString = "Rechercher, saisir une adresse ou une commande"
        field.delegate = self
        field.cell?.usesSingleLineMode = true
        field.cell?.isScrollable = true

        separator.boxType = .separator

        let column = NSTableColumn(identifier: .init("result"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = Self.rowHeight
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.style = .plain
        table.selectionHighlightStyle = .regular
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked)
        table.refusesFirstResponder = true
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false

        footer.font = .systemFont(ofSize: 11)
        footer.textColor = .tertiaryLabelColor

        let stack = NSStackView(views: [field, separator, scroll, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 10, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        tableHeight = scroll.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            field.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 18),
            field.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -18),
            separator.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28),
            footer.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 18),
            tableHeight,
        ])
    }

    required init?(coder: NSCoder) { fatalError("non utilisé") }

    func present(text: String, newTab: Bool) {
        isNewTab = newTab
        field.stringValue = text
        footer.stringValue = newTab ? "↩ ouvrir · ⌘↩ dans l'onglet actuel · ↑↓ choisir · Échap fermer"
                                    : "↩ ouvrir ici · ⌘↩ dans un nouvel onglet · ↑↓ choisir · Échap fermer"
        isHidden = false
        field.selectText(nil)
    }

    /// Affiche de nouveaux résultats. `keepSelection` : vrai quand des suggestions arrivent après coup.
    func show(results newResults: [CommandResult], keepSelection: Bool = false) {
        let previous = keepSelection ? table.selectedRow : 0
        results = newResults
        table.reloadData()
        tableHeight.constant = CGFloat(results.count) * Self.rowHeight
        separator.isHidden = results.isEmpty
        if !results.isEmpty { select(min(max(previous, 0), results.count - 1)) }
    }

    private func select(_ row: Int) {
        guard results.indices.contains(row) else { return }
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
        // Le verbe (« Basculer », « Ouvrir »…) n'apparaît que sur la ligne choisie.
        for index in results.indices { (table.view(atColumn: 0, row: index, makeIfNecessary: false) as? ResultCellView)?.isChosen = index == row }
    }

    @objc private func rowClicked() {
        guard results.indices.contains(table.clickedRow) else { return }
        onExecute?(results[table.clickedRow], query, false)
    }

    // MARK: Clavier

    func controlTextDidChange(_ notification: Notification) { onQueryChange?(query) }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            select(min(table.selectedRow + 1, results.count - 1)); return true
        case #selector(NSResponder.moveUp(_:)):
            select(max(table.selectedRow - 1, 0)); return true
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            submit(invert: false); return true
        case #selector(NSResponder.cancelOperation(_:)):
            onCancel?(); return true
        default:
            return false
        }
    }

    /// Cmd+Entrée : un champ de texte ne le reçoit jamais comme « Entrée » (les combinaisons avec Cmd passent
    /// d'abord par les raccourcis). On l'intercepte donc ici, avant le champ.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !isHidden, flags == .command, event.keyCode == 36 || event.keyCode == 76 else { return super.performKeyEquivalent(with: event) }
        submit(invert: true)
        return true
    }

    private func submit(invert: Bool) {
        let chosen = results.indices.contains(table.selectedRow) ? results[table.selectedRow] : nil
        onExecute?(chosen, query, invert)
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { results.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = (tableView.makeView(withIdentifier: ResultCellView.identifier, owner: self) as? ResultCellView) ?? ResultCellView()
        cell.configure(with: results[row])
        cell.isChosen = row == tableView.selectedRow
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { ChosenRowView() }

    func tableViewSelectionDidChange(_ notification: Notification) {
        for index in results.indices { (table.view(atColumn: 0, row: index, makeIfNecessary: false) as? ResultCellView)?.isChosen = index == table.selectedRow }
    }
}

/// Ligne choisie : fond teinté, même quand le focus est dans le champ de saisie.
private final class ChosenRowView: NSTableRowView {
    override var isEmphasized: Bool { get { true } set {} }
    /// Garde le texte lisible : sans ça, AppKit passe le texte de la ligne choisie en blanc
    /// (style « sur fond d'accent »), illisible sur notre fond teinté clair.
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
    override func drawSelection(in dirtyRect: NSRect) {
        NSColor.controlAccentColor.withAlphaComponent(0.16).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 8, yRadius: 8).fill()
    }
}

/// Une ligne de résultat : repère coloré, titre, sous-titre, étiquettes et verbe d'action.
@MainActor
private final class ResultCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("ResultCell")
    private let badge = NSView()
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")
    private let pill = NSTextField(labelWithString: "")
    private let star = NSImageView()
    private let action = NSTextField(labelWithString: "")

    var isChosen = false { didSet { action.isHidden = !isChosen } }

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 7
        icon.symbolConfiguration = .init(pointSize: 13, weight: .semibold)
        icon.contentTintColor = .white
        title.font = .systemFont(ofSize: 13.5, weight: .medium)
        title.lineBreakMode = .byTruncatingTail
        subtitle.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingMiddle
        pill.font = .systemFont(ofSize: 10.5, weight: .semibold)
        pill.wantsLayer = true
        pill.layer?.cornerRadius = 8
        pill.alignment = .center
        star.image = NSImage(systemSymbolName: "star.fill", accessibilityDescription: "Favori")
        star.contentTintColor = .systemYellow
        star.symbolConfiguration = .init(pointSize: 11, weight: .bold)
        action.font = .systemFont(ofSize: 11, weight: .medium)
        action.textColor = .secondaryLabelColor
        action.isHidden = true

        let texts = NSStackView(views: [title, subtitle])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 1
        for view in [badge, icon, texts, pill, star, action] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        texts.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        subtitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            badge.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
            badge.widthAnchor.constraint(equalToConstant: 28), badge.heightAnchor.constraint(equalToConstant: 28),
            icon.centerXAnchor.constraint(equalTo: badge.centerXAnchor), icon.centerYAnchor.constraint(equalTo: badge.centerYAnchor),
            texts.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: 12),
            texts.centerYAnchor.constraint(equalTo: centerYAnchor),
            pill.leadingAnchor.constraint(greaterThanOrEqualTo: texts.trailingAnchor, constant: 10),
            pill.centerYAnchor.constraint(equalTo: centerYAnchor),
            star.leadingAnchor.constraint(equalTo: pill.trailingAnchor, constant: 8),
            star.centerYAnchor.constraint(equalTo: centerYAnchor),
            action.leadingAnchor.constraint(equalTo: star.trailingAnchor, constant: 10),
            action.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            action.centerYAnchor.constraint(equalTo: centerYAnchor),
            action.widthAnchor.constraint(equalToConstant: 82),
        ])
        action.alignment = .right
    }

    required init?(coder: NSCoder) { fatalError("non utilisé") }

    func configure(with result: CommandResult) {
        title.stringValue = result.title
        subtitle.stringValue = result.subtitle
        action.stringValue = "\(result.actionLabel) ↩"
        star.isHidden = !result.isFavorite
        let (symbol, color) = Self.style(for: result.kind)
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        badge.layer?.backgroundColor = color.cgColor
        switch result.kind {
        case .openTab(_, let space): showPill("Ouvert · \(space)", color: .systemGreen)
        case .archived(_, let space): showPill(space.isEmpty ? "Archivé" : "Archivé · \(space)", color: .systemBrown)
        case .bitwarden(_, let space): showPill(space.map { "Bitwarden · \($0)" } ?? "Bitwarden", color: .systemBlue)
        case .clipboard(_, .secret, let bitwarden): showPill(bitwarden ? "Bitwarden · Touch ID" : "Masqué · Touch ID", color: bitwarden ? .systemBlue : .systemRed)
        default: pill.isHidden = true
        }
    }

    private func showPill(_ text: String, color: NSColor) {
        pill.stringValue = "  \(text)  "
        pill.textColor = color
        pill.layer?.backgroundColor = color.withAlphaComponent(0.15).cgColor
        pill.isHidden = false
    }

    /// Repères visuels définis en F4.
    static func style(for kind: CommandResult.Kind) -> (String, NSColor) {
        switch kind {
        case .openTab: ("square.on.square", .systemGreen)
        case .archived: ("archivebox.fill", .systemBrown)
        case .bitwarden: ("shield.lefthalf.filled", .systemBlue)
        case .clipboard(_, .secret, _): ("key.fill", .systemRed)
        case .clipboard(_, .link, _): ("link", .systemPurple)
        case .clipboard: ("doc.on.clipboard.fill", .systemPurple)
        case .favorite: ("star.fill", .systemYellow)
        case .history: ("clock", .systemGray)
        case .address: ("globe", .systemBlue)
        case .search: ("magnifyingglass", .systemBlue)
        case .suggestion: ("magnifyingglass", .systemGray)
        case .command: ("bolt.fill", .systemOrange)
        }
    }
}
