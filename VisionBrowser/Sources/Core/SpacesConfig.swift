import Foundation

/// Description persistante d'un espace (le coffre de données WebKit est retrouvé par son identifiant).
struct SpaceRecord: Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    var colorIndex: Int
    /// Dossier Bitwarden relié à l'espace (F6). Sans réglage, un dossier du même nom est relié automatiquement.
    var bitwardenFolderID: String? = nil
}

/// Règle de routage : les liens de ce domaine (et de ses sous-domaines) s'ouvrent dans cet espace.
struct RoutingRule: Codable, Equatable, Sendable {
    var host: String
    var spaceID: UUID
}

/// Les espaces et les règles de routage. Logique pure, testée ; enregistrée dans `spaces.json`.
struct SpacesConfig: Codable, Equatable, Sendable {
    var spaces: [SpaceRecord]
    var rules: [RoutingRule]

    /// Identifiant de l'espace historique (celui de la phase 1) : ses cookies sont conservés.
    static let defaultSpaceID = UUID(uuidString: "7E5A0000-0000-4000-8000-0000000000A1")!
    static let initial = SpacesConfig(spaces: [SpaceRecord(id: defaultSpaceID, name: "Perso", colorIndex: 0)], rules: [])
    /// Nombre de couleurs de la palette (voir `Space.palette`).
    static let paletteCount = 8

    // MARK: Espaces

    /// Ajoute un espace ; nom vide → « Espace n » ; nom déjà pris → suffixe « 2 », « 3 »…
    @discardableResult
    mutating func addSpace(named rawName: String, id: UUID = UUID()) -> SpaceRecord {
        let base = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let record = SpaceRecord(id: id, name: uniqueName(base.isEmpty ? "Espace \(spaces.count + 1)" : base), colorIndex: nextColor())
        spaces.append(record)
        return record
    }

    mutating func rename(_ id: UUID, to rawName: String) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let index = spaces.firstIndex(where: { $0.id == id }) else { return }
        if spaces[index].name == name { return }
        spaces[index].name = uniqueName(name)
    }

    /// Supprime un espace et ses règles. Le dernier espace ne peut pas être supprimé.
    @discardableResult
    mutating func remove(_ id: UUID) -> Bool {
        guard spaces.count > 1, spaces.contains(where: { $0.id == id }) else { return false }
        spaces.removeAll { $0.id == id }
        rules.removeAll { $0.spaceID == id }
        return true
    }

    func space(_ id: UUID) -> SpaceRecord? { spaces.first { $0.id == id } }

    /// Relie un dossier Bitwarden à un espace (nil : retour au lien automatique par le nom).
    /// Un dossier n'est relié qu'à un seul espace.
    mutating func linkBitwardenFolder(_ folderID: String?, to spaceID: UUID) {
        if let folderID {
            for i in spaces.indices where spaces[i].bitwardenFolderID == folderID { spaces[i].bitwardenFolderID = nil }
        }
        guard let index = spaces.firstIndex(where: { $0.id == spaceID }) else { return }
        spaces[index].bitwardenFolderID = folderID
    }

    private func uniqueName(_ name: String) -> String {
        let taken = Set(spaces.map { $0.name.lowercased() })
        guard taken.contains(name.lowercased()) else { return name }
        var n = 2
        while taken.contains("\(name) \(n)".lowercased()) { n += 1 }
        return "\(name) \(n)"
    }

    /// Première couleur de la palette pas encore utilisée (sinon on recommence le tour).
    private func nextColor() -> Int {
        let used = Set(spaces.map(\.colorIndex))
        return (0..<Self.paletteCount).first { !used.contains($0) } ?? spaces.count % Self.paletteCount
    }

    // MARK: Routage

    /// Ajoute ou remplace la règle de ce domaine.
    mutating func route(host rawHost: String, to spaceID: UUID) {
        let host = Self.normalizedHost(rawHost)
        guard !host.isEmpty, space(spaceID) != nil else { return }
        rules.removeAll { $0.host == host }
        rules.append(RoutingRule(host: host, spaceID: spaceID))
    }

    mutating func removeRoute(host: String) { rules.removeAll { $0.host == Self.normalizedHost(host) } }

    /// Espace prévu pour cette adresse : la règle la plus précise (le domaine le plus long) l'emporte.
    func spaceID(for url: URL) -> UUID? {
        guard let host = url.host(percentEncoded: false).map(Self.normalizedHost) else { return nil }
        return rules
            .filter { host == $0.host || host.hasSuffix("." + $0.host) }
            .max { $0.host.count < $1.host.count }?
            .spaceID
    }

    func rule(for host: String) -> RoutingRule? {
        rules.first { $0.host == Self.normalizedHost(host) }
    }

    static func normalizedHost(_ host: String) -> String {
        let lower = host.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return lower.hasPrefix("www.") ? String(lower.dropFirst(4)) : lower
    }
}

/// Lecture et écriture de `spaces.json`.
struct SpacesStore: Sendable {
    let fileURL: URL

    static var `default`: SpacesStore {
        SpacesStore(fileURL: AppPaths.applicationSupport.appendingPathComponent("spaces.json"))
    }

    func load() -> SpacesConfig {
        guard let data = try? Data(contentsOf: fileURL),
              let config = try? JSONDecoder().decode(SpacesConfig.self, from: data), !config.spaces.isEmpty else { return .initial }
        return config
    }

    func save(_ config: SpacesConfig) {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(config).write(to: fileURL, options: .atomic)
        } catch {
            NSLog("Vision Browser : échec de l'enregistrement des espaces : \(error.localizedDescription)")
        }
    }
}
