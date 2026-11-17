import XCTest
@testable import Vision_Browser

@MainActor
final class TaskStoreTests: XCTestCase {
    private func store() throws -> TaskStore { try TaskStore(path: ":memory:") }

    func testAddUpdateAndReadBack() throws {
        let s = try store()
        let task = try XCTUnwrap(s.add(title: "  Relancer le devis ", project: "Clients", sub: "Studio Mer", spaceID: "A", due: "2026-11-20"))
        XCTAssertEqual(task.title, "Relancer le devis")
        XCTAssertEqual(task.status, .todo)
        s.update(task.id, .init(status: .doing, notes: "Appeler avant midi"))
        let read = try XCTUnwrap(s.task(task.id))
        XCTAssertEqual(read.status, .doing)
        XCTAssertEqual(read.notes, "Appeler avant midi")
        XCTAssertEqual(read.project, "Clients")
        XCTAssertEqual(read.due, "2026-11-20")
        XCTAssertNil(s.add(title: "   ", spaceID: nil), "une tâche sans titre n'est pas créée")
    }

    func testDueCanBeClearedButIsKeptWhenAbsent() throws {
        let s = try store()
        let id = try XCTUnwrap(s.add(title: "T", spaceID: nil, due: "2026-11-20")).id
        let keep = try JSONDecoder().decode(TaskStore.Changes.self, from: Data(#"{"title":"T2"}"#.utf8))
        s.update(id, keep)
        XCTAssertEqual(s.task(id)?.due, "2026-11-20")
        let clear = try JSONDecoder().decode(TaskStore.Changes.self, from: Data(#"{"due":null}"#.utf8))
        s.update(id, clear)
        XCTAssertNil(s.task(id)?.due)
    }

    func testSubtasksAndLinksFollowTheTaskAndGoWithIt() throws {
        let s = try store()
        let id = try XCTUnwrap(s.add(title: "T", spaceID: nil)).id
        s.addSubtask(to: id, title: "Chiffrage")
        s.addSubtask(to: id, title: "Envoi")
        s.addLink(to: id, url: URL(string: "https://exemple.fr/brief")!, title: "Brief")
        s.addLink(to: id, url: URL(string: "https://exemple.fr/brief")!, title: "Brief")
        s.addLink(to: id, url: URL(string: "javascript:alert(1)")!, title: "Piège")
        var task = try XCTUnwrap(s.task(id))
        XCTAssertEqual(task.subtasks.map(\.title), ["Chiffrage", "Envoi"])
        XCTAssertEqual(task.links.count, 1, "une adresse liée une seule fois, et seulement du web")
        s.setSubtask(task.subtasks[0].id, done: true)
        task = try XCTUnwrap(s.task(id))
        XCTAssertTrue(task.subtasks[0].done)
        s.delete(id)
        XCTAssertTrue(s.all().isEmpty)
    }

    // MARK: Saisie rapide

    /// Mardi 17 novembre 2026.
    private let today: Date = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = .current
        return c.date(from: DateComponents(year: 2026, month: 11, day: 17))!
    }()
    private func parse(_ text: String) -> QuickTask { QuickTask.parse(text, today: today, calendar: Calendar(identifier: .gregorian)) }

    func testQuickTaskReadsProjectSubProjectAndDue() {
        XCTAssertEqual(parse("Relancer le devis #Clients/Studio Mer !demain"),
                       QuickTask(title: "Relancer le devis", project: "Clients", sub: "Studio Mer", due: "2026-11-18"))
        XCTAssertEqual(parse("Facturer #Gestion"), QuickTask(title: "Facturer", project: "Gestion", sub: nil, due: nil))
        XCTAssertEqual(parse("Appeler !ven le plombier").title, "Appeler le plombier")
    }

    func testQuickTaskDates() {
        XCTAssertEqual(parse("x !auj").due, "2026-11-17")
        XCTAssertEqual(parse("x !ven").due, "2026-11-20")
        XCTAssertEqual(parse("x !mardi").due, "2026-11-24", "le jour même : la semaine suivante")
        XCTAssertEqual(parse("x !24/11").due, "2026-11-24")
        XCTAssertEqual(parse("x !3/1").due, "2027-01-03", "date passée : l'an prochain")
        XCTAssertEqual(parse("x !10j").due, "2026-11-27")
        XCTAssertEqual(parse("Attention !important").due, nil, "un mot inconnu reste dans le titre")
        XCTAssertEqual(parse("Attention !important").title, "Attention !important")
    }
}
