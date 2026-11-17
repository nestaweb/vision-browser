import AppKit

/// Fenêtre Réglages (⌘,) : un onglet par thème, dans la barre d'outils, comme les réglages des apps macOS.
///
/// Chaque contrôle écrit directement dans `BrowserSettings` : le navigateur relit les réglages à chaque usage,
/// donc un changement s'applique tout de suite. Pour ajouter un thème : un `NSViewController` de plus dans `panes`.
@MainActor
final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    private init() {
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        for (pane, title, symbol) in [(GeneralSettingsPane(), "Général", "gearshape"),
                                      (SearchSettingsPane(), "Recherche", "magnifyingglass")] as [(NSViewController, String, String)] {
            pane.title = title  // sinon la fenêtre s'appelle « Untitled » (titre repris du volet affiché)
            let item = NSTabViewItem(viewController: pane)
            item.label = title
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            tabs.addTabViewItem(item)
        }
        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.title = "Réglages"
        window.toolbarStyle = .preference
        super.init(window: window)
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("non utilisé") }

    func show() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}

// MARK: Volets

/// Mise en page commune : libellés à droite, contrôles à gauche, notes en petit sous le contrôle.
@MainActor
private class SettingsPane: NSViewController {
    let settings = BrowserSettings()
    private let grid = NSGridView()

    override func loadView() {
        grid.rowSpacing = 10
        grid.columnSpacing = 12
        grid.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: container.topAnchor, constant: 24),
            grid.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -24),
            grid.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 32),
            grid.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -32),
            container.widthAnchor.constraint(equalToConstant: 520),
        ])
        view = container
        build()
        grid.column(at: 0).xPlacement = .trailing
        // La fenêtre prend la taille du contenu (sinon les lignes s'étirent sur toute la hauteur).
        preferredContentSize = container.fittingSize
    }

    func build() {}

    func addRow(_ label: String, _ control: NSView, note: String? = nil) {
        grid.addRow(with: [NSTextField(labelWithString: label), control])
        if let note {
            grid.addRow(with: [NSGridCell.emptyContentView, Self.note(note)])
        }
    }

    /// Note sous un contrôle : largeur fixe, sinon le texte qui passe à la ligne est mal mesuré (coupé).
    static func note(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        label.preferredMaxLayoutWidth = 280
        label.widthAnchor.constraint(equalToConstant: 280).isActive = true
        return label
    }

    func popUp(_ titles: [String], selected: Int, action: Selector) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.addItems(withTitles: titles)
        button.selectItem(at: max(selected, 0))
        button.target = self
        button.action = action
        return button
    }
}

@MainActor
private final class GeneralSettingsPane: SettingsPane {
    override func build() {
        let sleep = BrowserSettings.sleepChoices
        addRow("Mettre en veille les onglets après :",
               popUp(sleep.map { "\($0) min sans usage" }, selected: sleep.firstIndex(of: settings.sleepAfterMinutes) ?? 1,
                     action: #selector(sleepChanged(_:))),
               note: "Un onglet en veille libère sa mémoire ; il garde sa page, son historique et sa position.")
        let archive = BrowserSettings.archiveChoices
        addRow("Archiver les onglets après :",
               popUp(archive.map { $0 >= 48 ? "\($0 / 24) jours sans consultation" : "\($0) h sans consultation" },
                     selected: archive.firstIndex(of: settings.archiveAfterHours) ?? 1, action: #selector(archiveChanged(_:))),
               note: "Les onglets épinglés ne sont jamais archivés. Les onglets archivés restent dans la vue d'ensemble et dans Cmd+T.")
    }

    @objc private func sleepChanged(_ sender: NSPopUpButton) {
        settings.sleepAfterMinutes = BrowserSettings.sleepChoices[sender.indexOfSelectedItem]
    }

    @objc private func archiveChanged(_ sender: NSPopUpButton) {
        settings.archiveAfterHours = BrowserSettings.archiveChoices[sender.indexOfSelectedItem]
    }
}

@MainActor
private final class SearchSettingsPane: SettingsPane {
    private let suggestions = NSButton(checkboxWithTitle: "Suggestions pendant la saisie dans Cmd+T", target: nil, action: nil)
    private let suggestionsNote = SettingsPane.note("")

    override func build() {
        let engines = SearchEngine.all
        addRow("Moteur de recherche :",
               popUp(engines.map(\.name), selected: engines.firstIndex(of: settings.searchEngine) ?? 0, action: #selector(engineChanged(_:))))
        suggestions.target = self
        suggestions.action = #selector(suggestionsChanged(_:))
        addRow("", suggestions)
        refresh()
        addRow("", suggestionsNote)
    }

    private func refresh() {
        let engine = settings.searchEngine
        let available = engine.suggestTemplate != nil
        suggestions.isEnabled = available
        suggestions.state = available && settings.searchSuggestions ? .on : .off
        suggestionsNote.stringValue = available
            ? "Ce que tu tapes est envoyé à \(engine.name) pendant la saisie, et à lui seul."
            : "\(engine.name) ne propose pas de suggestions : rien n'est envoyé pendant la saisie."
    }

    @objc private func engineChanged(_ sender: NSPopUpButton) {
        settings.searchEngine = SearchEngine.all[sender.indexOfSelectedItem]
        refresh()
    }

    @objc private func suggestionsChanged(_ sender: NSButton) {
        settings.searchSuggestions = sender.state == .on
        refresh()
    }
}
