import Foundation

/// Ce que l'organisateur sait d'un onglet (sans WebKit : testable).
struct TabInfo: Equatable, Sendable {
    var id: UUID
    var url: URL?
    var title: String?
    var isPinned = false
    var isAwake = true
    var lastActivated: Date
}

/// Un élément de la section « Onglets » de la vue d'ensemble : un onglet seul, ou une pile d'onglets du même site.
enum TabGroup: Equatable, Sendable {
    case single(TabInfo)
    case stack(site: String, tabs: [TabInfo])

    var tabs: [TabInfo] {
        switch self {
        case .single(let tab): [tab]
        case .stack(_, let tabs): tabs
        }
    }
}

/// Règles de rangement des onglets : ordre récent, veille, archivage, piles, filtre.
/// Logique pure : l'interface (étagère, vue d'ensemble, Ctrl+Tab) ne fait qu'afficher le résultat.
enum TabOrganizer {
    /// Mise en veille après 8 min sans usage par défaut (Réglages ; essais : `-VBSleepAfterSeconds 30`).
    static var sleepAfter: TimeInterval { BrowserSettings().sleepAfter }

    /// Archivage après 12 h sans consultation par défaut (Réglages ; essais : `-VBArchiveAfterHours 24`).
    static var archiveAfter: TimeInterval { BrowserSettings().archiveAfter }

    /// Nombre d'onglets à partir duquel un site forme une pile.
    static let stackThreshold = 3
    /// Onglets récents montrés dans l'étagère.
    static let shelfRecentCount = 6

    /// Du plus récemment utilisé au plus ancien (ordre de `Ctrl+Tab`).
    static func recentFirst(_ tabs: [TabInfo]) -> [TabInfo] {
        tabs.enumerated().sorted { a, b in
            a.element.lastActivated != b.element.lastActivated ? a.element.lastActivated > b.element.lastActivated : a.offset < b.offset
        }.map(\.element)
    }

    /// Étagère : les épinglés (ordre stable), puis les 6 onglets non épinglés les plus récents.
    static func shelf(_ tabs: [TabInfo]) -> (pinned: [TabInfo], recent: [TabInfo]) {
        (tabs.filter(\.isPinned), Array(recentFirst(tabs.filter { !$0.isPinned }).prefix(shelfRecentCount)))
    }

    /// Onglets à endormir : éveillés, pas affichés, inutilisés depuis `sleepAfter`.
    static func sleepCandidates(_ tabs: [TabInfo], activeID: UUID?, now: Date, after: TimeInterval = sleepAfter) -> [UUID] {
        tabs.filter { $0.isAwake && $0.id != activeID && now.timeIntervalSince($0.lastActivated) >= after }.map(\.id)
    }

    /// Onglets à archiver : ni épinglés, ni affichés, non consultés depuis `archiveAfter`.
    static func archiveCandidates(_ tabs: [TabInfo], activeID: UUID?, now: Date, after: TimeInterval = archiveAfter) -> [UUID] {
        tabs.filter { !$0.isPinned && $0.id != activeID && now.timeIntervalSince($0.lastActivated) >= after }.map(\.id)
    }

    /// Les onglets non épinglés, dans leur ordre stable ; les sites ouverts 3 fois ou plus forment une pile,
    /// placée là où apparaît le premier onglet du site.
    static func groups(_ tabs: [TabInfo]) -> [TabGroup] {
        var bySite: [String: [TabInfo]] = [:]
        for tab in tabs { bySite[site(of: tab.url), default: []].append(tab) }
        var placed = Set<String>()
        var result: [TabGroup] = []
        for tab in tabs {
            let key = site(of: tab.url)
            let members = bySite[key] ?? []
            if !key.isEmpty, members.count >= stackThreshold {
                if placed.insert(key).inserted { result.append(.stack(site: key, tabs: members)) }
            } else {
                result.append(.single(tab))
            }
        }
        return result
    }

    /// Domaine « enregistrable » approché : `crm.zoho.eu` → `zoho.eu`, `www.bbc.co.uk` → `bbc.co.uk`.
    static func site(of url: URL?) -> String {
        guard let host = url?.host()?.lowercased(), !host.isEmpty else { return "" }
        if host.allSatisfy({ $0.isNumber || $0 == "." || $0 == ":" }) { return host }
        let labels = host.split(separator: ".").map(String.init)
        guard labels.count > 2 else { return labels.joined(separator: ".") }
        let secondLevel: Set<String> = ["co", "com", "org", "net", "gov", "ac", "edu", "gouv"]
        let keep = labels[labels.count - 1].count == 2 && secondLevel.contains(labels[labels.count - 2]) ? 3 : 2
        return labels.suffix(keep).joined(separator: ".")
    }

    /// Filtre de la vue d'ensemble : chaque mot tapé doit apparaître dans le titre ou l'adresse (sans accents).
    static func matches(_ tab: TabInfo, filter: String) -> Bool {
        matches(title: tab.title, url: tab.url, filter: filter)
    }

    static func matches(title: String?, url: URL?, filter: String) -> Bool {
        let words = normalize(filter).split(separator: " ")
        guard !words.isEmpty else { return true }
        let haystack = normalize("\(title ?? "") \(url?.absoluteString ?? "")")
        return words.allSatisfy { haystack.contains($0) }
    }

    static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}
