import Foundation

/// Instantané des onglets ouverts, rangés par espace, pour les rouvrir au lancement suivant.
struct SessionSnapshot: Codable, Equatable, Sendable {
    /// Un onglet. Les champs ajoutés en v3 ont une valeur par défaut : une session v2 se relit telle quelle.
    struct TabRecord: Codable, Equatable, Sendable {
        var id = UUID()
        var url: URL
        var title: String?
        var pinned = false
        /// Page d'accueil d'un onglet épinglé (bouton ↺).
        var homeURL: URL?
        var lastActivated: Date?

        init(id: UUID = UUID(), url: URL, title: String?, pinned: Bool = false, homeURL: URL? = nil, lastActivated: Date? = nil) {
            self.id = id; self.url = url; self.title = title; self.pinned = pinned; self.homeURL = homeURL; self.lastActivated = lastActivated
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
            url = try c.decode(URL.self, forKey: .url)
            title = try c.decodeIfPresent(String.self, forKey: .title)
            pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
            homeURL = try c.decodeIfPresent(URL.self, forKey: .homeURL)
            lastActivated = try c.decodeIfPresent(Date.self, forKey: .lastActivated)
        }
    }

    struct SpaceTabs: Codable, Equatable, Sendable {
        var spaceID: UUID
        var tabs: [TabRecord]
        var activeIndex: Int
    }

    var version = 3
    var spaces: [SpaceTabs]
    var activeSpaceID: UUID?
    /// Onglets rangés automatiquement (F2), retrouvables dans Cmd+T et la vue d'ensemble.
    var archived: [ArchivedTab] = []

    static let empty = SessionSnapshot(spaces: [], activeSpaceID: nil)

    init(spaces: [SpaceTabs], activeSpaceID: UUID?, archived: [ArchivedTab] = []) {
        self.spaces = spaces; self.activeSpaceID = activeSpaceID; self.archived = archived
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 2
        spaces = try c.decode([SpaceTabs].self, forKey: .spaces)
        activeSpaceID = try c.decodeIfPresent(UUID.self, forKey: .activeSpaceID)
        archived = try c.decodeIfPresent([ArchivedTab].self, forKey: .archived) ?? []
    }

    func tabs(in spaceID: UUID) -> SpaceTabs? { spaces.first { $0.spaceID == spaceID } }
}

/// Un onglet archivé : assez pour le retrouver et le rouvrir dans son espace.
struct ArchivedTab: Codable, Equatable, Sendable {
    var id: UUID
    var url: URL
    var title: String?
    var spaceID: UUID
    var archivedAt: Date

    /// On garde les 200 plus récents : au-delà, l'historique (Cmd+T) suffit.
    static let limit = 200
}

/// Lecture et écriture de la session sur disque (JSON).
/// Les fonctions d'encodage sont pures pour être testées sans toucher au disque.
struct SessionStore: Sendable {
    let fileURL: URL

    static var `default`: SessionStore {
        SessionStore(fileURL: AppPaths.applicationSupport.appendingPathComponent("session.json"))
    }

    static func encode(_ snapshot: SessionSnapshot) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(snapshot)
    }

    /// Format de la phase 1 (un seul espace) : migré vers l'espace par défaut.
    private struct LegacySnapshot: Decodable {
        var tabs: [SessionSnapshot.TabRecord]
        var activeIndex: Int
    }

    /// Une session illisible ou incohérente donne une session vide plutôt qu'un plantage.
    static func decode(_ data: Data, defaultSpaceID: UUID = SpacesConfig.defaultSpaceID) -> SessionSnapshot {
        var snapshot: SessionSnapshot
        if let current = try? JSONDecoder().decode(SessionSnapshot.self, from: data) {
            snapshot = current
        } else if let legacy = try? JSONDecoder().decode(LegacySnapshot.self, from: data) {
            snapshot = SessionSnapshot(spaces: [.init(spaceID: defaultSpaceID, tabs: legacy.tabs, activeIndex: legacy.activeIndex)],
                                       activeSpaceID: defaultSpaceID)
        } else {
            return .empty
        }
        snapshot.spaces = snapshot.spaces.map { space in
            var space = space
            space.tabs = space.tabs.filter { ["http", "https"].contains($0.url.scheme?.lowercased() ?? "") }
            space.activeIndex = space.tabs.isEmpty ? 0 : min(max(space.activeIndex, 0), space.tabs.count - 1)
            return space
        }
        snapshot.archived = Array(snapshot.archived.filter { ["http", "https"].contains($0.url.scheme?.lowercased() ?? "") }
            .sorted { $0.archivedAt > $1.archivedAt }.prefix(ArchivedTab.limit))
        snapshot.version = 3
        return snapshot
    }

    func load() -> SessionSnapshot {
        guard let data = try? Data(contentsOf: fileURL) else { return .empty }
        return Self.decode(data)
    }

    func save(_ snapshot: SessionSnapshot) {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Self.encode(snapshot).write(to: fileURL, options: .atomic)
        } catch {
            NSLog("Vision Browser : échec de l'enregistrement de la session : \(error.localizedDescription)")
        }
    }
}

enum AppPaths {
    /// ~/Library/Application Support/Vision Browser
    static var applicationSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Vision Browser", isDirectory: true)
    }

    /// Extensions installées par scripts/install-bitwarden.sh
    static var extensions: URL { applicationSupport.appendingPathComponent("Extensions", isDirectory: true) }
}
