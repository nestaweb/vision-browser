import AppKit

/// Menus et raccourcis. Les actions sont envoyées au premier répondeur
/// (la fenêtre de navigation), donc les raccourcis marchent même quand la page a le focus.
@MainActor
enum MainMenu {
    static let bitwardenMenuTitle = "Bitwarden"

    static func build() -> NSMenu {
        let main = NSMenu()

        main.addItem(submenu("Vision Browser", [
            item("À propos de Vision Browser", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator(),
            item("Masquer Vision Browser", #selector(NSApplication.hide(_:)), "h"),
            item("Masquer les autres", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            .separator(),
            item("Quitter Vision Browser", #selector(NSApplication.terminate(_:)), "q"),
        ]))

        main.addItem(submenu("Fichier", [
            item("Nouvel onglet", #selector(BrowserWindowController.newTabAction(_:)), "t"),
            item("Ouvrir l'adresse…", #selector(BrowserWindowController.editAddressAction(_:)), "l"),
            item("Rouvrir l'onglet fermé", #selector(BrowserWindowController.reopenClosedTabAction(_:)), "t", [.command, .shift]),
            .separator(),
            item("Fermer l'onglet", #selector(BrowserWindowController.closeTabAction(_:)), "w"),
        ]))

        // Indispensable : sans menu Édition, Cmd+C / Cmd+V ne marchent pas dans les pages.
        main.addItem(submenu("Édition", [
            item("Annuler", Selector(("undo:")), "z"),
            item("Rétablir", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("Couper", #selector(NSText.cut(_:)), "x"),
            item("Copier", #selector(NSText.copy(_:)), "c"),
            item("Coller", #selector(NSText.paste(_:)), "v"),
            item("Tout sélectionner", #selector(NSText.selectAll(_:)), "a"),
        ]))

        main.addItem(submenu("Présentation", [
            item("Recharger la page", #selector(BrowserWindowController.reloadAction(_:)), "r"),
            .separator(),
            item("Zoom avant", #selector(BrowserWindowController.zoomInAction(_:)), "+"),
            item("Zoom arrière", #selector(BrowserWindowController.zoomOutAction(_:)), "-"),
            item("Taille réelle", #selector(BrowserWindowController.zoomResetAction(_:)), "0"),
            .separator(),
            item("Plein écran", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
        ]))

        var tabItems: [NSMenuItem] = [
            item("Page précédente", #selector(BrowserWindowController.goBackAction(_:)), "["),
            item("Page suivante", #selector(BrowserWindowController.goForwardAction(_:)), "]"),
            .separator(),
            item("Onglet suivant", #selector(BrowserWindowController.nextTabAction(_:)), "\t", [.control]),
            item("Onglet précédent", #selector(BrowserWindowController.previousTabAction(_:)), "\t", [.control, .shift]),
            .separator(),
        ]
        for n in 1...9 {
            let menuItem = item("Onglet \(n)", #selector(BrowserWindowController.selectTabByNumberAction(_:)), "\(n)")
            menuItem.tag = n
            tabItems.append(menuItem)
        }
        main.addItem(submenu("Navigation", tabItems))

        let bitwarden = submenu(bitwardenMenuTitle, [
            item("Ouvrir Bitwarden", #selector(BrowserWindowController.openBitwardenAction(_:)), "b", [.command, .shift]),
        ])
        main.addItem(bitwarden)

        let window = submenu("Fenêtre", [
            item("Réduire", #selector(NSWindow.performMiniaturize(_:)), "m"),
        ])
        NSApp.windowsMenu = window.submenu
        main.addItem(window)
        return main
    }

    /// Ajoute les commandes de l'extension (ex. remplissage ⇧⌘L) à son menu, avec leurs raccourcis.
    static func installBitwardenMenu(host: ExtensionHost) {
        guard let menu = NSApp.mainMenu?.item(withTitle: bitwardenMenuTitle)?.submenu else { return }
        guard let context = host.context else {
            let missing = NSMenuItem(title: "Bitwarden n'est pas installé (scripts/install-bitwarden.sh)", action: nil, keyEquivalent: "")
            missing.isEnabled = false
            menu.addItem(.separator())
            menu.addItem(missing)
            return
        }
        let commands = context.commands.filter { $0.id != "_execute_browser_action" && $0.id != "_execute_action" }
        guard !commands.isEmpty else { return }
        menu.addItem(.separator())
        commands.forEach { menu.addItem($0.menuItem) }
    }

    private static func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        items.forEach { menu.addItem($0) }
        menuItem.submenu = menu
        return menuItem
    }

    private static func item(_ title: String, _ action: Selector, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: key)
        menuItem.keyEquivalentModifierMask = key.isEmpty ? [] : modifiers
        return menuItem
    }
}
