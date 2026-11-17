import Foundation

/// Un résultat de la barre `Cmd+T`, tous types confondus.
struct CommandResult: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case openTab(id: UUID, space: String)
        /// Onglet rangé automatiquement : le rouvrir dans son espace.
        case archived(id: UUID, space: String)
        /// Élément du presse-papier : ouvrir le lien, ou coller (Touch ID pour un secret).
        case clipboard(id: UUID, kind: ClipboardItem.Kind, bitwarden: Bool)
        /// Identifiant Bitwarden : ouvrir le site dans son espace et remplir.
        case bitwarden(id: String, space: String?)
        case favorite
        case history
        case address
        case search
        case suggestion
        case command(CommandID)
    }

    enum CommandID: Equatable, Sendable {
        case copyAddress
        case toggleFavorite
        case newSpace
        /// Renommer l'espace affiché.
        case renameSpace
        case switchSpace(UUID)
        case moveTab(UUID)
        /// « Toujours ouvrir ce site dans cet espace » (règle de routage).
        case routeHostHere
        case unlockBitwarden
        case lockBitwarden
        /// La CLI n'est pas connectée : expliquer `bw login`.
        case setupBitwarden
    }

    var kind: Kind
    var title: String
    var subtitle: String
    var url: URL?
    var isFavorite = false
    var score: Double
    /// Onglet ouvert dans un autre espace, proposé depuis un espace vide : Entrée le rouvre ici.
    var opensHere = false

    /// Verbe affiché à droite (« Basculer », « Ouvrir »…).
    var actionLabel: String {
        switch kind {
        case .openTab: opensHere ? "Ouvrir ici" : "Basculer"
        case .archived: "Rouvrir"
        case .clipboard(_, let kind, _): kind == .link ? "Ouvrir" : "Coller"
        case .bitwarden: "Remplir"
        case .favorite, .history, .address: "Ouvrir"
        case .search, .suggestion: "Rechercher"
        case .command: "Exécuter"
        }
    }

    /// ⌥↩ a une copie propre à ce résultat (mot de passe, élément du presse-papier) ;
    /// sinon ⌥↩ copie l'adresse du résultat.
    var isCopyable: Bool {
        switch kind {
        case .clipboard, .bitwarden: true
        default: false
        }
    }
}

/// Instantané d'un onglet ouvert, pour le moteur (sans dépendre de WebKit).
struct OpenTabInfo: Sendable {
    var id: UUID
    var url: URL?
    var title: String?
    var space: String
    var lastActivated: Date
}

/// Assemble les résultats des différentes sources et les classe.
/// Logique pure, testable ; les sources lentes (suggestions réseau) sont ajoutées après coup.
@MainActor
struct CommandBarEngine {
    let places: PlacesStore?

    /// Contexte des commandes : onglet actif et espaces.
    struct Context: Sendable {
        struct SpaceInfo: Sendable { var id: UUID; var name: String }
        var activeURL: URL?
        var activeIsFavorite: Bool
        var spaces: [SpaceInfo] = []
        var currentSpaceID: UUID?
        /// Espace où une règle envoie déjà le site actuel (pour ne pas proposer une règle inutile).
        var routedSpaceForActiveHost: UUID?
        /// État de la CLI Bitwarden (commandes Déverrouiller / Verrouiller).
        var bitwarden: BitwardenStatus = .notInstalled
        /// Déverrouillage en cours : on l'indique au lieu de proposer de recommencer.
        var bitwardenBusy = false
        /// L'espace affiché n'a aucun onglet.
        var currentSpaceIsEmpty = false
    }

    static let maxResults = 9

    /// - Parameter clipboard: l'historique du presse-papier (le moteur y cherche lui-même).
    func results(for rawQuery: String, tabs: [OpenTabInfo], context: Context, suggestions: [String] = [],
                 archived: [ArchivedTab] = [], clipboard: ClipboardHistory = ClipboardHistory(),
                 bitwarden: [BitwardenEntry] = [], now: Date = Date()) -> [CommandResult] {
        let list = rankedResults(for: rawQuery, tabs: tabs, context: context, suggestions: suggestions,
                                 archived: archived, clipboard: clipboard, bitwarden: bitwarden, now: now)
        // Espace vide : on vient d'y entrer pour l'utiliser. Un onglet ouvert ailleurs y est rouvert
        // (avec les cookies de cet espace) au lieu de nous renvoyer dans son espace.
        guard context.currentSpaceIsEmpty else { return list }
        return list.map { result in
            var result = result
            if case .openTab = result.kind { result.opensHere = true }
            return result
        }
    }

    private func rankedResults(for rawQuery: String, tabs: [OpenTabInfo], context: Context, suggestions: [String],
                               archived: [ArchivedTab], clipboard: ClipboardHistory,
                               bitwarden: [BitwardenEntry], now: Date) -> [CommandResult] {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty { return emptyQueryResults(tabs: tabs, clipboard: clipboard, now: now) }

        var results: [CommandResult] = []
        let tokens = PlacesStore.tokens(query)

        // 1. Ce que l'on a tapé : une adresse (toujours en tête) ou une recherche.
        switch AddressInput.parse(query) {
        case .url(let url):
            results.append(.init(kind: .address, title: url.absoluteString, subtitle: "Ouvrir cette adresse", url: url, score: 1_000))
        case .search(let text, let url):
            results.append(.init(kind: .search, title: text, subtitle: "Rechercher sur le web", url: url, score: 30))
        case nil: break
        }

        // 2. Onglets ouverts (tous les mots doivent apparaître dans le titre ou l'adresse).
        for tab in tabs {
            let haystack = Self.normalize("\(tab.title ?? "") \(tab.url?.absoluteString ?? "")")
            guard !tokens.isEmpty, tokens.allSatisfy({ haystack.contains($0) }) else { continue }
            let host = PlacesStore.host(tab.url ?? URL(string: "about:blank")!)
            let hostBonus = host.hasPrefix(tokens[0]) ? 60.0 : 0
            results.append(.init(kind: .openTab(id: tab.id, space: tab.space), title: tab.title?.nonEmpty ?? host,
                                 subtitle: host, url: tab.url, score: 70 + hostBonus))
        }

        // Une même page peut avoir plusieurs adresses (paramètres ajoutés après chargement, ex. `&ia=web`,
        // ou redirection) : on n'en garde qu'une par couple site + titre, la mieux placée.
        let pageKey = { (url: URL?, title: String?) in
            "\(PlacesStore.host(url ?? URL(string: "about:blank")!))|\(Self.normalize(title ?? url?.absoluteString ?? ""))"
        }
        var seenPages = Set(tabs.map { pageKey($0.url, $0.title) })

        // 3. Onglets archivés : sous les onglets ouverts, devant l'historique (on sait qu'on les avait gardés).
        let openKeys = Set(tabs.compactMap { $0.url.map(PlacesStore.key) })
        var archivedKeys = Set<String>()
        for entry in archived where !openKeys.contains(PlacesStore.key(entry.url)) {
            let haystack = Self.normalize("\(entry.title ?? "") \(entry.url.absoluteString)")
            guard !tokens.isEmpty, tokens.allSatisfy({ haystack.contains($0) }),
                  archivedKeys.insert(PlacesStore.key(entry.url)).inserted,
                  seenPages.insert(pageKey(entry.url, entry.title)).inserted else { continue }
            let host = PlacesStore.host(entry.url)
            let space = context.spaces.first { $0.id == entry.spaceID }?.name ?? ""
            results.append(.init(kind: .archived(id: entry.id, space: space), title: entry.title?.nonEmpty ?? host,
                                 subtitle: host, url: entry.url, score: 45 + (host.hasPrefix(tokens[0]) ? 40 : 0)))
        }

        // 4. Favoris et historique (une page déjà ouverte ou archivée n'est pas répétée).
        let shownKeys = openKeys.union(archivedKeys)
        for place in places?.search(query, limit: 8) ?? [] where !shownKeys.contains(PlacesStore.key(place.url)) {
            let host = PlacesStore.host(place.url)
            guard seenPages.insert(pageKey(place.url, place.title)).inserted else { continue }
            results.append(.init(kind: place.isFavorite ? .favorite : .history, title: place.title?.nonEmpty ?? host,
                                 subtitle: host, url: place.url, isFavorite: place.isFavorite, score: place.score))
        }

        // Bitwarden : comme un onglet ouvert, plus haut si le nom du site commence par ce qu'on tape.
        for (index, entry) in bitwarden.enumerated() {
            let host = entry.item.loginURL.map(PlacesStore.host) ?? ""
            let first = tokens.first ?? ""
            let nameMatch = !first.isEmpty && (Self.normalize(entry.item.name).hasPrefix(first) || host.hasPrefix(first))
            let details = [entry.item.username, host.isEmpty ? nil : host].compactMap { $0 }.joined(separator: " · ")
            results.append(.init(kind: .bitwarden(id: entry.item.id, space: entry.spaceName), title: entry.item.name,
                                 subtitle: details.isEmpty ? "Bitwarden" : details, url: entry.item.loginURL,
                                 score: 65 + (nameMatch ? 40 : 0) - Double(index)))
        }

        // Coffre verrouillé : on le signale dès qu'on cherche, sinon rien n'indique que des comptes sont cachés.
        if case .locked = context.bitwarden, query.count >= 3, !ClipboardHistory.wantsEverything(tokens),
           !results.contains(where: { $0.kind == .command(.unlockBitwarden) }) {
            results.append(.init(kind: .command(.unlockBitwarden),
                                 title: context.bitwardenBusy ? "Bitwarden se déverrouille… (quelques secondes)"
                                                              : "Déverrouiller Bitwarden pour chercher « \(query) »",
                                 subtitle: context.bitwardenBusy ? "Les comptes apparaîtront ici" : "Bitwarden verrouillé",
                                 url: nil, score: context.bitwardenBusy ? 90 : 25))
        }

        // Presse-papier : sous les onglets ouverts ; en tête si l'on tape « presse-papier », « copie »…
        let wantsClipboard = ClipboardHistory.wantsEverything(tokens)
        for (index, item) in clipboard.search(query).enumerated() {
            results.append(clipboardResult(item, now: now, score: (wantsClipboard ? 95 : 50) - Double(index)))
        }

        // 5. Commandes : proposées quand un mot de leur nom commence par ce qu'on tape.
        results += commands(matching: tokens, context: context)

        // 6. Suggestions du moteur de recherche (arrivent plus tard, ne passent jamais devant).
        let seen = Set(results.map { Self.normalize($0.title) })
        for (index, text) in suggestions.prefix(4).enumerated() where !seen.contains(Self.normalize(text)) {
            guard case .search(_, let url) = AddressInput.parse(text) else { continue }
            results.append(.init(kind: .suggestion, title: text, subtitle: "Suggestion de recherche", url: url, score: 20 - Double(index)))
        }

        return Array(results.sorted { $0.score > $1.score }.prefix(Self.maxResults))
    }

    /// `Cmd+T` sans rien taper : les onglets ouverts (récents d'abord), puis les favoris.
    func emptyQueryResults(tabs: [OpenTabInfo], clipboard: ClipboardHistory = ClipboardHistory(), now: Date = Date()) -> [CommandResult] {
        let recent = tabs.sorted { $0.lastActivated > $1.lastActivated }.prefix(6).enumerated().map { index, tab in
            CommandResult(kind: .openTab(id: tab.id, space: tab.space), title: tab.title?.nonEmpty ?? PlacesStore.host(tab.url ?? URL(string: "about:blank")!),
                          subtitle: tab.url.map(PlacesStore.host) ?? "", url: tab.url, score: 100 - Double(index))
        }
        let openKeys = Set(tabs.compactMap { $0.url.map(PlacesStore.key) })
        let favorites = (places?.favorites(limit: 6) ?? []).filter { !openKeys.contains(PlacesStore.key($0.url)) }.enumerated().map { index, place in
            CommandResult(kind: .favorite, title: place.title?.nonEmpty ?? PlacesStore.host(place.url), subtitle: PlacesStore.host(place.url),
                          url: place.url, isFavorite: true, score: 50 - Double(index))
        }
        // Ce qu'on vient de copier (moins de 5 min) : souvent, on ouvre Cmd+T précisément pour ça.
        let justCopied = clipboard.items.first.flatMap { now.timeIntervalSince($0.copiedAt) < 300 ? $0 : nil }
            .map { [clipboardResult($0, now: now, score: 75)] } ?? []
        return Array((recent + justCopied + favorites).sorted { $0.score > $1.score }.prefix(Self.maxResults))
    }

    private func clipboardResult(_ item: ClipboardItem, now: Date, score: Double) -> CommandResult {
        let origin = item.source.map { " · \($0)" } ?? ""
        let label = item.kind == .secret ? (item.fromBitwarden ? "Mot de passe" : "Secret") : "Copié"
        return CommandResult(kind: .clipboard(id: item.id, kind: item.kind, bitwarden: item.fromBitwarden),
                             title: ClipboardHistory.preview(of: item),
                             subtitle: "\(label) \(ClipboardHistory.age(of: item.copiedAt, now: now))\(origin)",
                             url: item.url, score: score)
    }

    private func commands(matching tokens: [String], context: Context) -> [CommandResult] {
        guard let first = tokens.first, first.count >= 2 else { return [] }
        var catalog: [(CommandResult.CommandID, String, String)] = [
            (.newSpace, "Nouvel espace", "nouvel nouveau espace creer"),
        ]
        if let current = context.spaces.first(where: { $0.id == context.currentSpaceID }) {
            catalog.append((.renameSpace, "Renommer l'espace « \(current.name) »", "renommer espace nom changer \(current.name)"))
        }
        switch context.bitwarden {
        case .locked: catalog.append((.unlockBitwarden, context.bitwardenBusy ? "Bitwarden se déverrouille… (quelques secondes)"
                                                                               : "Déverrouiller Bitwarden (recherche dans Cmd+T)",
                                      "bitwarden deverrouiller coffre mot passe identifiant"))
        case .unlocked: catalog.append((.lockBitwarden, "Verrouiller Bitwarden", "bitwarden verrouiller coffre"))
        case .unauthenticated: catalog.append((.setupBitwarden, "Bitwarden : connecter la CLI (bw login)", "bitwarden connecter cli coffre deverrouiller"))
        case .notInstalled: break
        }
        let others = context.spaces.filter { $0.id != context.currentSpaceID }
        catalog += others.map { (.switchSpace($0.id), "Aller à l'espace « \($0.name) »", "aller espace basculer \($0.name)") }
        if let url = context.activeURL {
            catalog += [
                (.copyAddress, "Copier l'adresse", "copier adresse url lien"),
                (.toggleFavorite, context.activeIsFavorite ? "Retirer des favoris" : "Ajouter aux favoris", "favori favoris ajouter retirer etoile"),
            ]
            catalog += others.map { (.moveTab($0.id), "Envoyer l'onglet vers « \($0.name) »", "envoyer deplacer onglet espace \($0.name)") }
            let host = PlacesStore.host(url)
            if !host.isEmpty, let current = context.spaces.first(where: { $0.id == context.currentSpaceID }),
               context.routedSpaceForActiveHost != current.id {
                catalog.append((.routeHostHere, "Toujours ouvrir \(host) dans « \(current.name) »", "toujours ouvrir regle lien espace \(host)"))
            }
        }
        return catalog.compactMap { id, title, keywords in
            let words = Self.normalize(keywords).split(separator: " ")
            guard tokens.allSatisfy({ token in words.contains { $0.hasPrefix(token) } }) else { return nil }
            return CommandResult(kind: .command(id), title: title, subtitle: "Commande", url: nil, score: 55)
        }
    }

    /// Minuscules, sans accents : « Facturé » et « facture » se valent.
    static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}

/// Suggestions du moteur de recherche choisi (format OpenSearch `[requête, [suggestions…]]`).
/// Rien n'est envoyé si les suggestions sont désactivées ou si le moteur n'en propose pas.
enum SearchSuggestions {
    static func requestURL(for query: String, settings: BrowserSettings = BrowserSettings()) -> URL? {
        guard settings.searchSuggestions else { return nil }
        return settings.searchEngine.suggestURL(for: query)
    }

    /// Lecture de la réponse ; renvoie une liste vide si le format est inattendu.
    static func parse(_ data: Data) -> [String] {
        guard let array = try? JSONSerialization.jsonObject(with: data) as? [Any], array.count >= 2,
              let list = array[1] as? [String] else { return [] }
        return list
    }

    /// Requête réseau ; annulée automatiquement si la tâche appelante est annulée (nouvelle frappe).
    static func fetch(_ query: String) async -> [String] {
        guard let url = requestURL(for: query) else { return [] }
        var request = URLRequest(url: url, timeoutInterval: 2)
        request.setValue("Vision Browser", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return [] }
        return parse(data)
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
