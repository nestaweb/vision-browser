import XCTest
@testable import Vision_Browser

final class SessionStoreTests: XCTestCase {
    private let perso = SpacesConfig.defaultSpaceID
    private let proB = UUID()

    func testRoundTripWithSpaces() throws {
        let snapshot = SessionSnapshot(spaces: [
            .init(spaceID: perso, tabs: [.init(url: URL(string: "https://github.com")!, title: "GitHub")], activeIndex: 0),
            .init(spaceID: proB, tabs: [.init(url: URL(string: "https://crm.zoho.eu")!, title: "CRM"),
                                        .init(url: URL(string: "https://mail.zoho.eu")!, title: nil)], activeIndex: 1),
        ], activeSpaceID: proB)
        XCTAssertEqual(SessionStore.decode(try SessionStore.encode(snapshot)), snapshot)
    }

    /// La session de la phase 1 (sans espaces) doit être reprise dans l'espace par défaut.
    func testPhaseOneSessionIsMigrated() {
        let legacy = Data("""
        {"activeIndex": 1, "tabs": [{"url": "https://accounts.zoho.com/signin", "title": ""},
                                    {"url": "https://github.com/nestaweb/vision-browser", "title": "GitHub"}], "version": 1}
        """.utf8)
        let snapshot = SessionStore.decode(legacy)
        XCTAssertEqual(snapshot.activeSpaceID, perso)
        XCTAssertEqual(snapshot.tabs(in: perso)?.tabs.map(\.url.host), ["accounts.zoho.com", "github.com"])
        XCTAssertEqual(snapshot.tabs(in: perso)?.activeIndex, 1)
    }

    /// Session de la phase 3 (v2) : relue sans perte, avec les valeurs par défaut des champs v3.
    func testPhaseThreeSessionIsRead() {
        let v2 = Data("""
        {"version": 2, "activeSpaceID": "\(perso.uuidString)",
         "spaces": [{"spaceID": "\(perso.uuidString)", "activeIndex": 0, "tabs": [{"url": "https://crm.zoho.eu", "title": "CRM"}]}]}
        """.utf8)
        let snapshot = SessionStore.decode(v2)
        XCTAssertEqual(snapshot.version, 3)
        let tab = snapshot.tabs(in: perso)?.tabs.first
        XCTAssertEqual(tab?.url.host, "crm.zoho.eu")
        XCTAssertEqual(tab?.pinned, false)
        XCTAssertNil(tab?.lastActivated)
        XCTAssertEqual(snapshot.archived, [])
    }

    func testPinnedAndArchivedRoundTrip() throws {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = SessionSnapshot(spaces: [.init(spaceID: perso, tabs: [
            .init(url: URL(string: "https://mail.zoho.eu/inbox")!, title: "Mail", pinned: true,
                  homeURL: URL(string: "https://mail.zoho.eu")!, lastActivated: date),
        ], activeIndex: 0)], activeSpaceID: perso, archived: [
            .init(id: UUID(), url: URL(string: "https://old.example.com")!, title: "Vieux", spaceID: perso, archivedAt: date),
        ])
        XCTAssertEqual(SessionStore.decode(try SessionStore.encode(snapshot)), snapshot)
    }

    func testCorruptDataGivesEmptySession() {
        XCTAssertEqual(SessionStore.decode(Data("pas du json".utf8)), .empty)
    }

    func testActiveIndexIsClampedAndNonWebTabsDropped() throws {
        let snapshot = SessionSnapshot(spaces: [.init(spaceID: perso, tabs: [
            .init(url: URL(string: "https://a.com")!, title: nil),
            .init(url: URL(string: "file:///etc/hosts")!, title: nil),
        ], activeIndex: 7)], activeSpaceID: perso)
        let decoded = SessionStore.decode(try SessionStore.encode(snapshot))
        XCTAssertEqual(decoded.tabs(in: perso)?.tabs.map(\.url.absoluteString), ["https://a.com"])
        XCTAssertEqual(decoded.tabs(in: perso)?.activeIndex, 0)
    }

    func testFileRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = SessionStore(fileURL: dir.appendingPathComponent("session.json"))
        XCTAssertEqual(store.load(), .empty)
        let snapshot = SessionSnapshot(spaces: [.init(spaceID: perso, tabs: [.init(url: URL(string: "https://zoho.com")!, title: "Zoho")], activeIndex: 0)],
                                       activeSpaceID: perso)
        store.save(snapshot)
        XCTAssertEqual(store.load(), snapshot)
        try? FileManager.default.removeItem(at: dir)
    }
}

final class DomainPolicyTests: XCTestCase {
    func testDisplayHostDropsWWW() {
        XCTAssertEqual(DomainPolicy.displayHost(for: URL(string: "https://www.Zoho.com/crm")), "zoho.com")
    }

    func testAnnounceOnlyWhenHostChanges() {
        let a = URL(string: "https://crm.zoho.eu/a")!, b = URL(string: "https://crm.zoho.eu/b")!, c = URL(string: "https://mail.zoho.eu")!
        XCTAssertTrue(DomainPolicy.shouldAnnounce(previous: nil, next: a))
        XCTAssertFalse(DomainPolicy.shouldAnnounce(previous: a, next: b))
        XCTAssertTrue(DomainPolicy.shouldAnnounce(previous: b, next: c))
        XCTAssertFalse(DomainPolicy.shouldAnnounce(previous: a, next: URL(string: "about:blank")))
    }

    func testInsecureDetection() {
        XCTAssertTrue(DomainPolicy.isInsecure(URL(string: "http://example.com")))
        XCTAssertFalse(DomainPolicy.isInsecure(URL(string: "https://example.com")))
        XCTAssertFalse(DomainPolicy.isInsecure(URL(string: "http://localhost:3000")))
        XCTAssertFalse(DomainPolicy.isInsecure(URL(string: "http://192.168.1.20")))
        XCTAssertTrue(DomainPolicy.isInsecure(URL(string: "http://8.8.8.8")))
    }
}
