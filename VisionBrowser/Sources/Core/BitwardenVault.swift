import Foundation

/// Un identifiant du coffre, tel que la recherche en a besoin. **Jamais de mot de passe ici** :
/// il est demandé à `bw` au dernier moment.
struct BitwardenItem: Equatable, Sendable {
    var id: String
    var name: String
    var username: String?
    var uris: [URL]
    var folderID: String?
    var favorite = false

    /// Première adresse web de l'élément (celle qu'on ouvre).
    var loginURL: URL? { uris.first { ["http", "https"].contains($0.scheme?.lowercased() ?? "") } }
}

struct BitwardenFolder: Equatable, Sendable {
    var id: String
    var name: String
}

enum BitwardenStatus: Equatable, Sendable {
    /// La CLI `bw` est introuvable.
    case notInstalled
    /// La CLI n'est connectée à aucun compte (`bw login` à faire).
    case unauthenticated
    case locked(email: String?)
    case unlocked(email: String?)
}

/// Lecture des sorties JSON de la CLI `bw`. Les champs inutiles (dont le mot de passe) ne sont pas lus.
enum BitwardenJSON {
    private struct RawItem: Decodable {
        struct Login: Decodable {
            struct URI: Decodable { var uri: String? }
            var username: String?
            var uris: [URI]?
        }
        var id: String
        var type: Int
        var name: String
        var folderId: String?
        var favorite: Bool?
        var login: Login?
        var deletedDate: String?
    }

    /// `bw list items` : uniquement les identifiants (type 1), hors corbeille.
    static func items(_ data: Data) throws -> [BitwardenItem] {
        try JSONDecoder().decode([RawItem].self, from: data).compactMap { raw in
            guard raw.type == 1, raw.deletedDate == nil, let login = raw.login else { return nil }
            let uris = (login.uris ?? []).compactMap { $0.uri.flatMap(normalizedURL) }
            return BitwardenItem(id: raw.id, name: raw.name, username: login.username?.nonEmptyValue, uris: uris,
                                 folderID: raw.folderId, favorite: raw.favorite ?? false)
        }
    }

    /// `bw list folders` (sans le pseudo-dossier « No Folder », dont l'identifiant est nul).
    static func folders(_ data: Data) throws -> [BitwardenFolder] {
        struct Raw: Decodable { var id: String?; var name: String }
        return try JSONDecoder().decode([Raw].self, from: data).compactMap { raw in raw.id.map { BitwardenFolder(id: $0, name: raw.name) } }
    }

    /// `bw status`.
    static func status(_ data: Data) -> BitwardenStatus {
        struct Raw: Decodable { var status: String; var userEmail: String? }
        guard let raw = try? JSONDecoder().decode(Raw.self, from: data) else { return .unauthenticated }
        switch raw.status {
        case "unlocked": return .unlocked(email: raw.userEmail)
        case "locked": return .locked(email: raw.userEmail)
        default: return .unauthenticated
        }
    }

    /// `bw get item <id>` : identifiant et mot de passe, pour un remplissage immédiat.
    static func credentials(_ data: Data) -> (username: String?, password: String?) {
        struct Raw: Decodable {
            struct Login: Decodable { var username: String?; var password: String? }
            var login: Login?
        }
        let raw = try? JSONDecoder().decode(Raw.self, from: data)
        return (raw?.login?.username?.nonEmptyValue, raw?.login?.password?.nonEmptyValue)
    }

    /// Bitwarden accepte des adresses sans schéma (« zoho.eu ») : on les complète en https.
    static func normalizedURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.contains("://") { return URL(string: trimmed) }
        return URL(string: "https://\(trimmed)")
    }
}

/// Un résultat de recherche, avec l'espace où l'ouvrir.
struct BitwardenEntry: Equatable, Sendable {
    var item: BitwardenItem
    var spaceID: UUID?
    var spaceName: String?
}

/// Le coffre tel que l'app le voit : recherche et choix de l'espace (F5 + F6).
struct BitwardenVault: Sendable {
    var items: [BitwardenItem] = []
    var folders: [BitwardenFolder] = []

    /// Espace d'un élément : dossier relié explicitement, sinon dossier du même nom que l'espace,
    /// sinon règle de routage du site, sinon aucun (l'espace affiché sera utilisé).
    func spaceID(for item: BitwardenItem, config: SpacesConfig) -> UUID? {
        if let folderID = item.folderID {
            if let linked = config.spaces.first(where: { $0.bitwardenFolderID == folderID }) { return linked.id }
            if let folder = folders.first(where: { $0.id == folderID }),
               let named = config.spaces.first(where: { $0.bitwardenFolderID == nil && Self.sameName($0.name, folder.name) }) {
                return named.id
            }
        }
        return item.loginURL.flatMap(config.spaceID(for:))
    }

    /// Tous les mots doivent apparaître dans le nom, l'identifiant ou les adresses (sans accents).
    /// Les éléments de l'espace affiché passent devant, puis les favoris.
    func search(_ query: String, config: SpacesConfig, currentSpaceID: UUID?, limit: Int = 5) -> [BitwardenEntry] {
        let words = TabOrganizer.normalize(query).split(separator: " ").map(String.init)
        guard !words.isEmpty, words.joined().count >= 2 else { return [] }
        let matches = items.filter { item in
            let hosts = item.uris.compactMap { $0.host() }.joined(separator: " ")
            let haystack = TabOrganizer.normalize("\(item.name) \(item.username ?? "") \(hosts)")
            return words.allSatisfy { haystack.contains($0) }
        }
        let entries = matches.map { item -> BitwardenEntry in
            let space = spaceID(for: item, config: config)
            return BitwardenEntry(item: item, spaceID: space, spaceName: space.flatMap { config.space($0)?.name })
        }
        return Array(entries.enumerated().sorted { a, b in
            let rank = { (e: BitwardenEntry) in (e.spaceID == currentSpaceID ? 2 : 0) + (e.item.favorite ? 1 : 0) }
            return rank(a.element) != rank(b.element) ? rank(a.element) > rank(b.element) : a.offset < b.offset
        }.map(\.element).prefix(limit))
    }

    static func sameName(_ a: String, _ b: String) -> Bool {
        TabOrganizer.normalize(a).trimmingCharacters(in: .whitespaces) == TabOrganizer.normalize(b).trimmingCharacters(in: .whitespaces)
    }

    /// Garde-fou anti-hameçonnage : on ne remplit que si la page est sur le site enregistré dans Bitwarden.
    static func pageMatches(_ pageURL: URL?, item: BitwardenItem) -> Bool {
        let site = TabOrganizer.site(of: pageURL)
        guard !site.isEmpty else { return false }
        return item.uris.contains { TabOrganizer.site(of: $0) == site }
    }
}

private extension String {
    var nonEmptyValue: String? { isEmpty ? nil : self }
}
