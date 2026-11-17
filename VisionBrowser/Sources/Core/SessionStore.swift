import Foundation

/// Instantané des onglets ouverts, pour les rouvrir au lancement suivant.
struct SessionSnapshot: Codable, Equatable, Sendable {
    struct TabRecord: Codable, Equatable, Sendable {
        var url: URL
        var title: String?
    }

    var version = 1
    var tabs: [TabRecord]
    var activeIndex: Int

    static let empty = SessionSnapshot(tabs: [], activeIndex: 0)
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

    /// Une session illisible ou incohérente donne une session vide plutôt qu'un plantage.
    static func decode(_ data: Data) -> SessionSnapshot {
        guard var snapshot = try? JSONDecoder().decode(SessionSnapshot.self, from: data) else { return .empty }
        snapshot.tabs = snapshot.tabs.filter { ["http", "https"].contains($0.url.scheme?.lowercased() ?? "") }
        snapshot.activeIndex = snapshot.tabs.isEmpty ? 0 : min(max(snapshot.activeIndex, 0), snapshot.tabs.count - 1)
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
