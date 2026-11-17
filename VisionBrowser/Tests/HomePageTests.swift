import XCTest
@testable import Vision_Browser

/// Le canal de la page d'accueil : ce que la page demande, ce que l'app enregistre et renvoie.
@MainActor
final class HomePageTests: XCTestCase {
    private func page() throws -> HomePage { HomePage(store: try TaskStore(path: ":memory:")) }

    private func tasks(_ json: String?) throws -> [[String: Any]] {
        let data = try XCTUnwrap(json?.data(using: .utf8))
        let state = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(state["tasks"] as? [[String: Any]])
    }

    func testAddParsesTheQuickSyntaxAndReturnsTheState() throws {
        let home = try page()
        let list = try tasks(home.handle("add", ["text": "Relancer le devis #Clients/Studio Mer !auj", "spaceID": "S1"]))
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list[0]["title"] as? String, "Relancer le devis")
        XCTAssertEqual(list[0]["project"] as? String, "Clients")
        XCTAssertEqual(list[0]["sub"] as? String, "Studio Mer")
        XCTAssertEqual(list[0]["due"] as? String, QuickTask.dayString(Date()))
        XCTAssertEqual(list[0]["spaceID"] as? String, "S1")
        XCTAssertEqual(list[0]["status"] as? String, "todo")
    }

    func testUpdateStatusSubtasksLinksAndDelete() throws {
        let home = try page()
        var list = try tasks(home.handle("add", ["text": "Tâche", "spaceID": "S1"]))
        let id = try XCTUnwrap(list[0]["id"] as? NSNumber)
        list = try tasks(home.handle("update", ["id": id, "changes": ["status": "doing", "due": "2026-12-01"]]))
        XCTAssertEqual(list[0]["status"] as? String, "doing")
        XCTAssertEqual(list[0]["due"] as? String, "2026-12-01")
        list = try tasks(home.handle("update", ["id": id, "changes": ["due": NSNull()]]))
        XCTAssertNil(list[0]["due"] as? String, "« Retirer » efface l'échéance")
        list = try tasks(home.handle("addSub", ["id": id, "title": "Chiffrage"]))
        XCTAssertEqual((list[0]["subtasks"] as? [[String: Any]])?.first?["title"] as? String, "Chiffrage")
        list = try tasks(home.handle("addLink", ["id": id, "url": "exemple.fr/brief", "title": ""]))
        XCTAssertEqual((list[0]["links"] as? [[String: Any]])?.first?["url"] as? String, "https://exemple.fr/brief")
        list = try tasks(home.handle("addLink", ["id": id, "url": "javascript:alert(1)", "title": ""]))
        XCTAssertEqual((list[0]["links"] as? [[String: Any]])?.count, 1, "seules les adresses web se lient")
        list = try tasks(home.handle("delete", ["id": id]))
        XCTAssertTrue(list.isEmpty)
    }

    func testUnknownRequestsAnswerNothing() throws {
        XCTAssertNil(try page().handle("rm -rf", [:]))
    }
}
