import AppKit

/// Menus et raccourcis. Les actions sont envoyées au premier répondeur
/// (la fenêtre de navigation), donc les raccourcis marchent même quand la page a le focus.
@MainActor
enum MainMenu {
    static let bitwardenMenuTitle = "Bitwarden"
    static let spacesMenuTitle = "Espaces"

    /// Reconstruit le menu « Espaces » : liste (Ctrl+1…9, coche sur l'espace affiché), gestion, envoi d'onglet.
    static func updateSpacesMenu(for browser: BrowserWindowController) {
        guard let menu = NSApp.mainMenu?.item(withTitle: spacesMenuTitle)?.submenu else { return }
        menu.removeAllItems()
        for (index, space) in browser.spaces.enumerated() {
            let entry = item(space.name, #selector(BrowserWindowController.switchSpaceByNumberAction(_:)),
                             index < 9 ? "\(index + 1)" : "", [.control])
            entry.tag = index + 1
            entry.image = space.swatch
            entry.state = space === browser.currentSpace ? .on : .off
            menu.addItem(entry)
        }
        menu.addItem(.separator())
        // Sans ⌘ : dans un champ de la page, la page garde ⇧← ⇧→ (sélection) ; ailleurs, on change d'espace.
        menu.addItem(item("Espace précédent", #selector(BrowserWindowController.previousSpaceAction(_:)), arrow(NSLeftArrowFunctionKey), [.shift]))
        menu.addItem(item("Espace suivant", #selector(BrowserWindowController.nextSpaceAction(_:)), arrow(NSRightArrowFunctionKey), [.shift]))
        menu.addItem(.separator())
        menu.addItem(item("Nouvel espace…", #selector(BrowserWindowController.newSpaceAction(_:)), "n", [.command, .shift]))
        menu.addItem(item("Renommer l'espace…", #selector(BrowserWindowController.renameSpaceAction(_:))))
        menu.addItem(item("Supprimer l'espace…", #selector(BrowserWindowController.deleteSpaceAction(_:))))
        menu.addItem(.separator())
        let others = browser.spaces.filter { $0 !== browser.currentSpace }
        let move = submenu("Envoyer l'onglet vers", others.map { space in
            let entry = item(space.name, #selector(BrowserWindowController.moveTabToSpaceAction(_:)))
            entry.representedObject = space.id
            entry.image = space.swatch
            return entry
        })
        move.isEnabled = !others.isEmpty
        menu.addItem(move)
        menu.addItem(item("Toujours ouvrir ce site dans cet espace", #selector(BrowserWindowController.routeHostHereAction(_:))))
        menu.addItem(.separator())
        menu.addItem(bitwardenFolderMenu(for: browser))
    }

    static func build() -> NSMenu {
        let main = NSMenu()

        main.addItem(submenu("Vision Browser", [
            item("À propos de Vision Browser", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator(),
            item("Réglages…", #selector(AppDelegate.showSettings(_:)), ","),
            .separator(),
            item("Masquer Vision Browser", #selector(NSApplication.hide(_:)), "h"),
            item("Masquer les autres", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            .separator(),
            item("Quitter Vision Browser", #selector(NSApplication.terminate(_:)), "q"),
        ]))

        main.addItem(submenu("Fichier", [
            item("Nouvel onglet", #selector(BrowserWindowController.newTabAction(_:)), "t"),
            item("Modifier l'adresse…", #selector(BrowserWindowController.editAddressAction(_:)), "l"),
            item("Rouvrir l'onglet fermé", #selector(BrowserWindowController.reopenClosedTabAction(_:)), "t", [.command, .shift]),
            item("Épingler l'onglet", #selector(BrowserWindowController.togglePinAction(_:)), "d"),
            item("Ajouter aux favoris / Retirer", #selector(BrowserWindowController.toggleFavoriteAction(_:)), "d", [.command, .shift]),
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
            item("Vue d'ensemble des onglets", #selector(BrowserWindowController.showOverviewAction(_:)), "o", [.command, .shift]),
            alternate(#selector(BrowserWindowController.showOverviewAction(_:)), "\\", [.command, .shift]),
            .separator(),
            item("Zoom avant", #selector(BrowserWindowController.zoomInAction(_:)), "="),
            alternate(#selector(BrowserWindowController.zoomInAction(_:)), "+"),
            item("Zoom arrière", #selector(BrowserWindowController.zoomOutAction(_:)), "-"),
            item("Taille réelle", #selector(BrowserWindowController.zoomResetAction(_:)), "0"),
            .separator(),
            item("Plein écran", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
        ]))

        var tabItems: [NSMenuItem] = [
            // ⌘← ⌘→ : tapables sur tous les claviers (⌘[ ⌘] demandent ⌥ sur un clavier français, gardés en secours).
            // Dans un champ de la page, la page les utilise d'abord (début / fin de ligne).
            item("Page précédente", #selector(BrowserWindowController.goBackAction(_:)), arrow(NSLeftArrowFunctionKey)),
            item("Page suivante", #selector(BrowserWindowController.goForwardAction(_:)), arrow(NSRightArrowFunctionKey)),
            alternate(#selector(BrowserWindowController.goBackAction(_:)), "["),
            alternate(#selector(BrowserWindowController.goForwardAction(_:)), "]"),
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

        // Rempli par `updateSpacesMenu` (la liste des espaces change à l'usage).
        main.addItem(submenu(spacesMenuTitle, []))

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

    /// « Dossier Bitwarden » : quel dossier du coffre correspond à l'espace affiché (F6).
    private static func bitwardenFolderMenu(for browser: BrowserWindowController) -> NSMenuItem {
        let service = BitwardenService.shared
        guard service.isUnlocked else {
            let locked = NSMenuItem(title: "Dossier Bitwarden (déverrouille Bitwarden pour choisir)", action: nil, keyEquivalent: "")
            locked.isEnabled = false
            return locked
        }
        let linked = browser.config.space(browser.currentSpace.id)?.bitwardenFolderID
        let sameName = service.vault.folders.first { BitwardenVault.sameName($0.name, browser.currentSpace.name) }
        let automatic = item(sameName.map { "Automatique (dossier « \($0.name) »)" } ?? "Automatique (aucun dossier de ce nom)",
                             #selector(BrowserWindowController.linkBitwardenFolderAction(_:)))
        automatic.state = linked == nil ? .on : .off
        var entries = [automatic, NSMenuItem.separator()]
        for folder in service.vault.folders {
            let entry = item(folder.name, #selector(BrowserWindowController.linkBitwardenFolderAction(_:)))
            entry.representedObject = folder.id
            entry.state = linked == folder.id ? .on : .off
            entries.append(entry)
        }
        return submenu("Dossier Bitwarden de l'espace", entries)
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

    /// Raccourci de secours : invisible dans le menu, mais actif (ex. ⌘[ sur un clavier QWERTY).
    private static func alternate(_ action: Selector, _ key: String, _ modifiers: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
        let menuItem = item("", action, key, modifiers)
        menuItem.isHidden = true
        menuItem.allowsKeyEquivalentWhenHidden = true
        return menuItem
    }

    private static func arrow(_ key: Int) -> String { String(Character(UnicodeScalar(UInt32(key))!)) }

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
