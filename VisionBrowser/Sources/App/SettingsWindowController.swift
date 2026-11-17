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
                                      (SearchSettingsPane(), "Recherche", "magnifyingglass"),
                                      (ShortcutSettingsPane(), "Raccourcis", "keyboard")] as [(NSViewController, String, String)] {
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

@MainActor
private final class ShortcutSettingsPane: SettingsPane {
    private let recorder = ShortcutRecorder()
    private let reset = NSButton(title: "Rétablir ⌘@", target: nil, action: nil)
    private let message = SettingsPane.note("")

    override func build() {
        recorder.shortcut = settings.overviewShortcut
        recorder.onRecord = { [weak self] shortcut in self?.record(shortcut) }
        reset.target = self
        reset.action = #selector(resetShortcut)
        let controls = NSStackView(views: [recorder, reset])
        controls.spacing = 8
        addRow("Vue d'ensemble des onglets :", controls)
        addRow("", message)
        showHint()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        recorder.stopRecording()
    }

    private func record(_ shortcut: KeyShortcut) {
        if let problem = shortcut.problem { return showError(problem) }
        if let owner = MainMenu.owner(of: shortcut) { return showError("\(shortcut.display) sert déjà à « \(owner) ».") }
        save(shortcut)
    }

    @objc private func resetShortcut() {
        recorder.stopRecording()
        save(.overviewDefault)
    }

    private func save(_ shortcut: KeyShortcut) {
        settings.overviewShortcut = shortcut
        recorder.shortcut = shortcut
        MainMenu.applyOverviewShortcut(shortcut)
        showHint()
    }

    private func showHint() {
        reset.isEnabled = settings.overviewShortcut != .overviewDefault
        message.textColor = .secondaryLabelColor
        message.stringValue = "Clique sur le raccourci puis tape le nouveau (Échap annule). Le même raccourci referme la vue d'ensemble. "
            + "Échap l'ouvre aussi, quand la page ne s'en sert pas."
    }

    private func showError(_ text: String) {
        message.textColor = .systemRed
        message.stringValue = text + " Essaie une autre combinaison."
    }
}

/// Bouton qui affiche un raccourci ; cliqué, il attend la combinaison suivante et la transmet.
///
/// La frappe est lue par un moniteur local : sans lui, une combinaison avec ⌘ partirait d'abord vers les menus
/// (et déclencherait la commande au lieu d'être enregistrée).
@MainActor
private final class ShortcutRecorder: NSButton {
    var shortcut = KeyShortcut.overviewDefault { didSet { refresh() } }
    var onRecord: ((KeyShortcut) -> Void)?
    private var monitor: Any?

    init() {
        super.init(frame: .zero)
        bezelStyle = .push
        setButtonType(.momentaryPushIn)
        font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        target = self
        action = #selector(toggle)
        widthAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("non utilisé") }

    @objc private func toggle() {
        monitor == nil ? startRecording() : stopRecording()
    }

    private func startRecording() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
            if event.keyCode == 53, flags.isEmpty { self.stopRecording(); return nil }
            // Rangée des chiffres : la touche physique, comme les raccourcis ⌘1…9 (⌘& sur un clavier français = ⌘1).
            let key = BrowserWindowController.digitRow[event.keyCode].map(String.init) ?? event.charactersIgnoringModifiers ?? ""
            let shortcut = KeyShortcut(key: key, modifiers: UInt(flags.rawValue))
            self.stopRecording()
            self.onRecord?(shortcut)
            return nil
        }
        refresh()
    }

    func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        refresh()
    }

    private func refresh() {
        title = monitor == nil ? shortcut.display : "Tape le raccourci…"
    }
}
