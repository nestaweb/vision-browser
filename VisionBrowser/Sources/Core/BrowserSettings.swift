import Foundation

/// Un moteur de recherche : adresse des résultats et, s'il en propose, adresse des suggestions
/// au format OpenSearch (`[requête, [suggestions…]]`).
struct SearchEngine: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    /// Adresse des résultats ; `%s` est remplacé par la requête encodée.
    let searchTemplate: String
    /// Adresse des suggestions ; `nil` si le moteur n'en propose pas dans ce format.
    let suggestTemplate: String?

    func searchURL(for query: String) -> URL? { URL(string: Self.fill(searchTemplate, with: query)) }
    func suggestURL(for query: String) -> URL? { suggestTemplate.flatMap { URL(string: Self.fill($0, with: query)) } }

    private static func fill(_ template: String, with query: String) -> String {
        template.replacingOccurrences(of: "%s", with: query.addingPercentEncoding(withAllowedCharacters: .queryValueAllowed) ?? query)
    }

    /// Les suggestions sont envoyées **au moteur choisi**, jamais à un autre (ce qu'on tape ne part pas ailleurs).
    static let all: [SearchEngine] = [
        .init(id: "duckduckgo", name: "DuckDuckGo", searchTemplate: "https://duckduckgo.com/?q=%s",
              suggestTemplate: "https://duckduckgo.com/ac/?q=%s&type=list"),
        .init(id: "google", name: "Google", searchTemplate: "https://www.google.com/search?q=%s",
              suggestTemplate: "https://suggestqueries.google.com/complete/search?client=firefox&q=%s"),
        .init(id: "bing", name: "Bing", searchTemplate: "https://www.bing.com/search?q=%s",
              suggestTemplate: "https://api.bing.com/osjson.aspx?query=%s"),
        .init(id: "qwant", name: "Qwant", searchTemplate: "https://www.qwant.com/?q=%s", suggestTemplate: nil),
        .init(id: "ecosia", name: "Ecosia", searchTemplate: "https://www.ecosia.org/search?q=%s",
              suggestTemplate: "https://ac.ecosia.org/autocomplete?q=%s&type=list"),
        .init(id: "brave", name: "Brave Search", searchTemplate: "https://search.brave.com/search?q=%s",
              suggestTemplate: "https://search.brave.com/api/suggest?q=%s"),
        .init(id: "startpage", name: "Startpage", searchTemplate: "https://www.startpage.com/do/search?q=%s", suggestTemplate: nil),
    ]

    static let fallback = all[0]
    static func engine(id: String?) -> SearchEngine { all.first { $0.id == id } ?? fallback }
}

/// Réglages de Vision Browser, gardés dans les préférences de l'app (`UserDefaults`).
///
/// Une seule source de vérité : la fenêtre Réglages écrit ici, le navigateur relit ici à chaque usage
/// (un changement s'applique tout de suite, sans relancer l'app).
struct BrowserSettings {
    enum Key {
        static let searchEngine = "VBSearchEngine"
        static let searchSuggestions = "VBSearchSuggestions"
        static let sleepAfterMinutes = "VBSleepAfterMinutes"
        /// Clé déjà utilisée comme option de lancement (`-VBArchiveAfterHours 24`) : reprise telle quelle.
        static let archiveAfterHours = "VBArchiveAfterHours"
        /// Option de lancement pour les essais (`-VBSleepAfterSeconds 30`) : prioritaire sur le réglage.
        static let sleepAfterSeconds = "VBSleepAfterSeconds"
        static let overviewShortcut = "VBOverviewShortcut"
    }

    /// Choix proposés dans la fenêtre Réglages.
    static let sleepChoices = [5, 8, 15, 30, 60]
    static let archiveChoices = [6, 12, 24, 48, 168]
    static let defaultSleepMinutes = 8
    static let defaultArchiveHours = 12

    let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var searchEngine: SearchEngine {
        get { SearchEngine.engine(id: defaults.string(forKey: Key.searchEngine)) }
        nonmutating set { defaults.set(newValue.id, forKey: Key.searchEngine) }
    }

    var searchSuggestions: Bool {
        get { defaults.object(forKey: Key.searchSuggestions) as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: Key.searchSuggestions) }
    }

    var sleepAfterMinutes: Int {
        get { positive(defaults.integer(forKey: Key.sleepAfterMinutes)) ?? Self.defaultSleepMinutes }
        nonmutating set { defaults.set(newValue, forKey: Key.sleepAfterMinutes) }
    }

    var archiveAfterHours: Int {
        get { positive(Int(defaults.double(forKey: Key.archiveAfterHours))) ?? Self.defaultArchiveHours }
        nonmutating set { defaults.set(Double(newValue), forKey: Key.archiveAfterHours) }
    }

    /// Délai de mise en veille effectif (l'option de lancement des essais passe avant le réglage).
    var sleepAfter: TimeInterval {
        let seconds = defaults.double(forKey: Key.sleepAfterSeconds)
        return seconds > 0 ? seconds : TimeInterval(sleepAfterMinutes * 60)
    }

    var archiveAfter: TimeInterval { TimeInterval(archiveAfterHours * 3600) }

    /// Raccourci de la vue d'ensemble (la Scène) ; ⌘@ par défaut.
    var overviewShortcut: KeyShortcut {
        get {
            guard let stored = defaults.dictionary(forKey: Key.overviewShortcut), let key = stored["key"] as? String,
                  let modifiers = stored["modifiers"] as? Int else { return .overviewDefault }
            let shortcut = KeyShortcut(key: key, modifiers: UInt(modifiers))
            return shortcut.problem == nil ? shortcut : .overviewDefault
        }
        nonmutating set {
            if newValue == .overviewDefault { return defaults.removeObject(forKey: Key.overviewShortcut) }
            defaults.set(["key": newValue.key, "modifiers": Int(newValue.modifiers)], forKey: Key.overviewShortcut)
        }
    }

    private func positive(_ value: Int) -> Int? { value > 0 ? value : nil }
}

/// Un raccourci clavier : un caractère et des touches de modification, au format des menus macOS.
///
/// Les valeurs des modificateurs sont celles d'AppKit (`NSEvent.ModifierFlags`), pour passer telles quelles au menu.
/// Le cœur reste sans AppKit (testable seul).
struct KeyShortcut: Equatable, Sendable {
    static let shift: UInt = 1 << 17, control: UInt = 1 << 18, option: UInt = 1 << 19, command: UInt = 1 << 20

    /// Le caractère, en minuscule pour une lettre (Maj est alors dans `modifiers`).
    let key: String
    let modifiers: UInt

    init(key: String, modifiers: UInt) {
        let mods = modifiers & (Self.shift | Self.control | Self.option | Self.command)
        // ⇧⌘O arrive en « O » : on garde « o » et Maj, comme le veulent les menus.
        if key.count == 1, key.lowercased() != key.uppercased(), key == key.uppercased() {
            self.key = key.lowercased()
            self.modifiers = mods | Self.shift
        } else {
            self.key = key
            self.modifiers = mods
        }
    }

    static let overviewDefault = KeyShortcut(key: "@", modifiers: command)

    /// Pourquoi ce raccourci est refusé, ou `nil` s'il convient.
    var problem: String? {
        guard key.count == 1, let scalar = key.unicodeScalars.first,
              !CharacterSet.whitespacesAndNewlines.contains(scalar), !CharacterSet.controlCharacters.contains(scalar),
              !(0xF700...0xF8FF).contains(scalar.value) else { return "Choisis une touche de caractère (lettre, chiffre, signe)." }
        guard modifiers & (Self.command | Self.control | Self.option) != 0 else {
            return "Ajoute ⌘, ⌃ ou ⌥ : seule, la touche servirait à taper du texte."
        }
        return nil
    }

    /// « ⌘@ », « ⌃⌥K » : dans l'ordre des menus macOS.
    var display: String {
        var text = ""
        if modifiers & Self.control != 0 { text += "⌃" }
        if modifiers & Self.option != 0 { text += "⌥" }
        if modifiers & Self.shift != 0 { text += "⇧" }
        if modifiers & Self.command != 0 { text += "⌘" }
        return text + key.uppercased()
    }
}

extension CharacterSet {
    /// Caractères laissés tels quels dans une valeur de paramètre (on encode aussi & = + ? #).
    static let queryValueAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "&=+?#")
        return set
    }()
}
