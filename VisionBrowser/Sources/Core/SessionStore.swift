import Foundation

/// Instantané des onglets ouverts, rangés par espace, pour les rouvrir au lancement suivant.
struct SessionSnapshot: Codable, Equatable, Sendable {
    struct TabRecord: Codable, Equatable, Sendable {
        var url: URL
        var title: String?
    }

    struct SpaceTabs: Codable, Equatable, Sendable {
        var spaceID: UUID
        var tabs: [TabRecord]
        var activeIndex: Int
    }

    var version = 2
    var spaces: [SpaceTabs]
    var activeSpaceID: UUID?

    static let empty = SessionSnapshot(spaces: [], activeSpaceID: nil)

    func tabs(in spaceID: UUID) -> SpaceTabs? { spaces.first { $0.spaceID == spaceID } }
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
