import WebKit

/// Un espace = un coffre de données WebKit indépendant (cookies, stockage local, cache).
/// L'identifiant est fixe : les sessions persistent d'un lancement à l'autre.
/// Phase 1 : un seul espace ; les espaces multiples arrivent en phase 3.
@MainActor
final class Space {
    let name: String
    let id: UUID
    let store: WKWebsiteDataStore

    init(name: String, id: UUID) {
        self.name = name
        self.id = id
        self.store = WKWebsiteDataStore(forIdentifier: id)
    }

    static let personal = Space(name: "Perso", id: UUID(uuidString: "7E5A0000-0000-4000-8000-0000000000A1")!)
}
