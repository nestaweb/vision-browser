import XCTest
@testable import Vision_Browser

final class SessionStoreTests: XCTestCase {
    func testRoundTrip() throws {
        let snapshot = SessionSnapshot(tabs: [
            .init(url: URL(string: "https://crm.zoho.eu")!, title: "CRM"),
            .init(url: URL(string: "https://github.com")!, title: nil),
        ], activeIndex: 1)
        XCTAssertEqual(SessionStore.decode(try SessionStore.encode(snapshot)), snapshot)
    }

    func testCorruptDataGivesEmptySession() {
        XCTAssertEqual(SessionStore.decode(Data("pas du json".utf8)), .empty)
    }

    func testActiveIndexIsClampedAndNonWebTabsDropped() throws {
        let snapshot = SessionSnapshot(tabs: [
            .init(url: URL(string: "https://a.com")!, title: nil),
            .init(url: URL(string: "file:///etc/hosts")!, title: nil),
        ], activeIndex: 7)
        let decoded = SessionStore.decode(try SessionStore.encode(snapshot))
        XCTAssertEqual(decoded.tabs.map(\.url.absoluteString), ["https://a.com"])
        XCTAssertEqual(decoded.activeIndex, 0)
    }

    func testFileRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = SessionStore(fileURL: dir.appendingPathComponent("session.json"))
        XCTAssertEqual(store.load(), .empty)
        let snapshot = SessionSnapshot(tabs: [.init(url: URL(string: "https://zoho.com")!, title: "Zoho")], activeIndex: 0)
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
