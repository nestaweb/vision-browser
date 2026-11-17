import Foundation

/// Un résultat de la barre `Cmd+T`, tous types confondus.
struct CommandResult: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case openTab(id: UUID, space: String)
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
        case switchSpace(UUID)
        case moveTab(UUID)
        /// « Toujours ouvrir ce site dans cet espace » (règle de routage).
        case routeHostHere
    }

    var kind: Kind
    var title: String
    var subtitle: String
    var url: URL?
    var isFavorite = false
    var score: Double

    /// Verbe affiché à droite (« Basculer », « Ouvrir »…).
    var actionLabel: String {
        switch kind {
        case .openTab: "Basculer"
        case .favorite, .history, .address: "Ouvrir"
        case .search, .suggestion: "Rechercher"
        case .command: "Exécuter"
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
    }

    static let maxResults = 9

    func results(for rawQuery: String, tabs: [OpenTabInfo], context: Context, suggestions: [String] = []) -> [CommandResult] {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty { return emptyQueryResults(tabs: tabs) }

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

        // 3. Favoris et historique (une adresse déjà ouverte en onglet n'est pas répétée).
        let openKeys = Set(tabs.compactMap { $0.url.map(PlacesStore.key) })
        // Une même page peut avoir plusieurs adresses (paramètres ajoutés après chargement, ex. `&ia=web`) :
        // on n'en garde qu'une par couple site + titre, la mieux classée.
        var seenPages = Set(tabs.map { "\(PlacesStore.host($0.url ?? URL(string: "about:blank")!))|\(Self.normalize($0.title ?? ""))" })
        for place in places?.search(query, limit: 8) ?? [] where !openKeys.contains(PlacesStore.key(place.url)) {
            let host = PlacesStore.host(place.url)
            guard seenPages.insert("\(host)|\(Self.normalize(place.title ?? place.url.absoluteString))").inserted else { continue }
            results.append(.init(kind: place.isFavorite ? .favorite : .history, title: place.title?.nonEmpty ?? host,
                                 subtitle: host, url: place.url, isFavorite: place.isFavorite, score: place.score))
        }

        // 4. Commandes : proposées quand un mot de leur nom commence par ce qu'on tape.
        results += commands(matching: tokens, context: context)

        // 5. Suggestions du moteur de recherche (arrivent plus tard, ne passent jamais devant).
        let seen = Set(results.map { Self.normalize($0.title) })
        for (index, text) in suggestions.prefix(4).enumerated() where !seen.contains(Self.normalize(text)) {
            guard case .search(_, let url) = AddressInput.parse(text) else { continue }
            results.append(.init(kind: .suggestion, title: text, subtitle: "Suggestion de recherche", url: url, score: 20 - Double(index)))
        }

        return Array(results.sorted { $0.score > $1.score }.prefix(Self.maxResults))
    }

    /// `Cmd+T` sans rien taper : les onglets ouverts (récents d'abord), puis les favoris.
    func emptyQueryResults(tabs: [OpenTabInfo]) -> [CommandResult] {
        let recent = tabs.sorted { $0.lastActivated > $1.lastActivated }.prefix(6).enumerated().map { index, tab in
            CommandResult(kind: .openTab(id: tab.id, space: tab.space), title: tab.title?.nonEmpty ?? PlacesStore.host(tab.url ?? URL(string: "about:blank")!),
                          subtitle: tab.url.map(PlacesStore.host) ?? "", url: tab.url, score: 100 - Double(index))
        }
        let openKeys = Set(tabs.compactMap { $0.url.map(PlacesStore.key) })
        let favorites = (places?.favorites(limit: 6) ?? []).filter { !openKeys.contains(PlacesStore.key($0.url)) }.enumerated().map { index, place in
            CommandResult(kind: .favorite, title: place.title?.nonEmpty ?? PlacesStore.host(place.url), subtitle: PlacesStore.host(place.url),
                          url: place.url, isFavorite: true, score: 50 - Double(index))
        }
        return Array((recent + favorites).prefix(Self.maxResults))
    }

    private func commands(matching tokens: [String], context: Context) -> [CommandResult] {
        guard let first = tokens.first, first.count >= 2 else { return [] }
        var catalog: [(CommandResult.CommandID, String, String)] = [
            (.newSpace, "Nouvel espace", "nouvel nouveau espace creer"),
        ]
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

/// Suggestions du moteur de recherche (DuckDuckGo, format `[requête, [suggestions…]]`).
enum SearchSuggestions {
    static func requestURL(for query: String) -> URL? {
        var components = URLComponents(string: "https://duckduckgo.com/ac/")
        components?.queryItems = [.init(name: "q", value: query), .init(name: "type", value: "list")]
        return components?.url
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
