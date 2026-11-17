import XCTest
@testable import Vision_Browser

final class TabOrganizerTests: XCTestCase {
    private let now = Date()

    private func tab(_ url: String, ago: TimeInterval = 0, pinned: Bool = false, awake: Bool = true, title: String? = nil) -> TabInfo {
        TabInfo(id: UUID(), url: URL(string: url), title: title, isPinned: pinned, isAwake: awake, lastActivated: now.addingTimeInterval(-ago))
    }

    func testRecentFirstIsStableForTies() {
        let a = tab("https://a.com", ago: 10), b = tab("https://b.com", ago: 5), c = tab("https://c.com", ago: 10)
        XCTAssertEqual(TabOrganizer.recentFirst([a, b, c]).map(\.url?.host), ["b.com", "a.com", "c.com"])
    }

    func testSleepSparesActiveAndRecentTabs() {
        let active = tab("https://a.com", ago: 3_600), old = tab("https://b.com", ago: 600),
            fresh = tab("https://c.com", ago: 60), asleep = tab("https://d.com", ago: 9_000, awake: false)
        let ids = TabOrganizer.sleepCandidates([active, old, fresh, asleep], activeID: active.id, now: now, after: 480)
        XCTAssertEqual(ids, [old.id])
    }

    func testArchiveNeverTakesPinnedOrActiveTabs() {
        let pinned = tab("https://a.com", ago: 90_000, pinned: true), active = tab("https://b.com", ago: 90_000),
            old = tab("https://c.com", ago: 50_000), recent = tab("https://d.com", ago: 3_600)
        let ids = TabOrganizer.archiveCandidates([pinned, active, old, recent], activeID: active.id, now: now, after: 12 * 3600)
        XCTAssertEqual(ids, [old.id])
    }

    func testSiteKey() {
        XCTAssertEqual(TabOrganizer.site(of: URL(string: "https://crm.zoho.eu/x")), "zoho.eu")
        XCTAssertEqual(TabOrganizer.site(of: URL(string: "https://www.bbc.co.uk")), "bbc.co.uk")
        XCTAssertEqual(TabOrganizer.site(of: URL(string: "https://github.com")), "github.com")
        XCTAssertEqual(TabOrganizer.site(of: URL(string: "http://192.168.1.20:8080")), "192.168.1.20")
        XCTAssertEqual(TabOrganizer.site(of: nil), "")
    }

    func testFilterIgnoresAccentsAndNeedsEveryWord() {
        let t = tab("https://books.zoho.eu/factures", title: "Factures à relancer")
        XCTAssertTrue(TabOrganizer.matches(t, filter: "facture RELANCER"))
        XCTAssertTrue(TabOrganizer.matches(t, filter: "zoho"))
        XCTAssertFalse(TabOrganizer.matches(t, filter: "factures payees"))
        XCTAssertTrue(TabOrganizer.matches(t, filter: "   "))
    }
}
