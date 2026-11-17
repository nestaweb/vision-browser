import Foundation

/// Interprète ce que l'utilisateur tape dans la barre d'adresse : une adresse ou une recherche.
/// Logique pure (aucune dépendance à l'interface), couverte par des tests.
enum AddressInput: Equatable, Sendable {
    case url(URL)
    case search(query: String, url: URL)

    var url: URL {
        switch self {
        case .url(let url): url
        case .search(_, let url): url
        }
    }

    /// Renvoie `nil` si la saisie est vide. Le moteur est celui choisi dans les Réglages.
    static func parse(_ raw: String, engine: SearchEngine = BrowserSettings().searchEngine) -> AddressInput? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        // 1. Adresse complète avec schéma (https://…, file://…, about:blank).
        if let url = URL(string: text), let scheme = url.scheme?.lowercased(),
           ["http", "https", "file", "about", "data"].contains(scheme),
           !text.contains(" ") {
            return .url(url)
        }

        // 2. Ressemble à un hôte : pas d'espace, et un point, « localhost » ou un port.
        if !text.contains(" "), looksLikeHost(text), let url = URL(string: defaultScheme(for: text) + text) {
            return .url(url)
        }

        // 3. Sinon, recherche.
        guard let url = engine.searchURL(for: text) else { return nil }
        return .search(query: text, url: url)
    }

    private static func looksLikeHost(_ text: String) -> Bool {
        let host = text.split(separator: "/", maxSplits: 1).first.map(String.init) ?? text
        let hostOnly = host.split(separator: ":").first.map(String.init) ?? host
        if hostOnly == "localhost" { return true }
        // Une extension après le dernier point (au moins 2 lettres) ou une adresse IP.
        let parts = hostOnly.split(separator: ".")
        guard parts.count >= 2, parts.allSatisfy({ !$0.isEmpty }) else { return false }
        if parts.allSatisfy({ Int($0) != nil }) { return parts.count == 4 }
        guard let tld = parts.last, tld.count >= 2, tld.allSatisfy(\.isLetter) else { return false }
        return true
    }

    /// Le développement local se fait en http ; tout le reste en https.
    private static func defaultScheme(for text: String) -> String {
        let host = text.split(separator: "/").first.map(String.init) ?? text
        let hostOnly = host.split(separator: ":").first.map(String.init) ?? host
        let isLocal = hostOnly == "localhost" || hostOnly.hasSuffix(".localhost") || hostOnly.hasSuffix(".test")
            || hostOnly.split(separator: ".").allSatisfy { Int($0) != nil }
        return isLocal ? "http://" : "https://"
    }
}
