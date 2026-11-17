import XCTest
@testable import Vision_Browser

final class SpacesConfigTests: XCTestCase {
    func testInitialConfigKeepsHistoricalSpace() {
        XCTAssertEqual(SpacesConfig.initial.spaces.map(\.id), [SpacesConfig.defaultSpaceID])
        XCTAssertEqual(SpacesConfig.initial.spaces.first?.name, "Perso")
    }

    func testAddSpaceNamesAndColors() {
        var config = SpacesConfig.initial
        let a = config.addSpace(named: "Pro A")
        let b = config.addSpace(named: "  ")
        let a2 = config.addSpace(named: "pro a")
        XCTAssertEqual([a.name, b.name, a2.name], ["Pro A", "Espace 3", "pro a 2"])
        XCTAssertEqual(Set(config.spaces.map(\.colorIndex)).count, 4, "chaque espace reçoit une couleur différente")
    }

    func testRenameKeepsNamesUnique() {
        var config = SpacesConfig.initial
        let a = config.addSpace(named: "Pro A")
        config.rename(a.id, to: "Perso")
        XCTAssertEqual(config.space(a.id)?.name, "Perso 2")
        config.rename(a.id, to: "   ")
        XCTAssertEqual(config.space(a.id)?.name, "Perso 2", "un nom vide est ignoré")
    }

    func testLastSpaceCannotBeRemovedAndRulesFollowRemoval() {
        var config = SpacesConfig.initial
        XCTAssertFalse(config.remove(SpacesConfig.defaultSpaceID))
        let b = config.addSpace(named: "Pro B")
        config.route(host: "zoho.eu", to: b.id)
        XCTAssertTrue(config.remove(b.id))
        XCTAssertTrue(config.rules.isEmpty)
    }

    func testMostSpecificRuleWins() {
        var config = SpacesConfig.initial
        let a = config.addSpace(named: "Pro A"), b = config.addSpace(named: "Pro B")
        config.route(host: "zoho.eu", to: a.id)
        config.route(host: "www.Crm.Zoho.eu", to: b.id)
        XCTAssertEqual(config.spaceID(for: URL(string: "https://crm.zoho.eu/crm/tab/Home")!), b.id)
        XCTAssertEqual(config.spaceID(for: URL(string: "https://mail.zoho.eu")!), a.id)
        XCTAssertEqual(config.spaceID(for: URL(string: "https://zoho.eu")!), a.id)
        XCTAssertNil(config.spaceID(for: URL(string: "https://notzoho.eu")!), "un autre domaine qui finit pareil ne doit pas correspondre")
        XCTAssertNil(config.spaceID(for: URL(string: "https://github.com")!))
    }

    func testRouteReplacesExistingRuleForSameHost() {
        var config = SpacesConfig.initial
        let a = config.addSpace(named: "Pro A"), b = config.addSpace(named: "Pro B")
        config.route(host: "zoho.eu", to: a.id)
        config.route(host: "zoho.eu", to: b.id)
        XCTAssertEqual(config.rules, [RoutingRule(host: "zoho.eu", spaceID: b.id)])
        config.route(host: "zoho.eu", to: UUID())
        XCTAssertEqual(config.rules.count, 1, "une règle vers un espace inconnu est ignorée")
    }

    func testStoreRoundTripAndFallback() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = SpacesStore(fileURL: dir.appendingPathComponent("spaces.json"))
        XCTAssertEqual(store.load(), .initial)
        var config = SpacesConfig.initial
        config.addSpace(named: "Pro A")
        store.save(config)
        XCTAssertEqual(store.load(), config)
        try Data("cassé".utf8).write(to: store.fileURL)
        XCTAssertEqual(store.load(), .initial, "un fichier illisible redonne la configuration initiale")
        try? FileManager.default.removeItem(at: dir)
    }
}
