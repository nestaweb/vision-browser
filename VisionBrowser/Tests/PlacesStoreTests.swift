import XCTest
@testable import Vision_Browser

@MainActor
final class PlacesStoreTests: XCTestCase {
    private func store() throws -> PlacesStore { try PlacesStore(path: ":memory:") }
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testVisitsAreCountedOncePerPage() throws {
        let s = try store()
        let url = URL(string: "https://books.zoho.eu/factures#ligne-3")!
        s.recordVisit(url: url, title: "Factures", at: now)
        s.recordVisit(url: URL(string: "https://books.zoho.eu/factures")!, title: nil, at: now)
        let results = s.search("factures", now: now)
        XCTAssertEqual(results.count, 1, "le fragment # ne doit pas créer une seconde entrée")
        XCTAssertEqual(results.first?.visitCount, 2)
        XCTAssertEqual(results.first?.title, "Factures", "un titre absent ne doit pas effacer le précédent")
    }

    func testSearchIgnoresAccentsAndMatchesPrefixes() throws {
        let s = try store()
        s.recordVisit(url: URL(string: "https://books.zoho.eu/1")!, title: "Facturé à Studio Nord", at: now)
        XCTAssertEqual(s.search("factur", now: now).count, 1)
        XCTAssertEqual(s.search("FACTURE studio", now: now).count, 1)
        XCTAssertEqual(s.search("nord fact", now: now).count, 1, "l'ordre des mots ne compte pas")
        XCTAssertTrue(s.search("inconnu", now: now).isEmpty)
    }

    func testHostPrefixWinsOverTitleMention() throws {
        let s = try store()
        s.recordVisit(url: URL(string: "https://blog.example.com/git")!, title: "Tutoriel git avancé", at: now)
        s.recordVisit(url: URL(string: "https://github.com/nestaweb/vision-browser")!, title: "vision-browser", at: now)
        XCTAssertEqual(s.search("git", now: now).first?.url.host(), "github.com")
    }

    func testFrequentAndRecentRankHigher() throws {
        let s = try store()
        let old = now.addingTimeInterval(-90 * 86_400)
        s.recordVisit(url: URL(string: "https://a.com/rapport")!, title: "Rapport annuel", at: old)
        for _ in 0..<10 { s.recordVisit(url: URL(string: "https://b.com/rapport")!, title: "Rapport mensuel", at: now) }
        XCTAssertEqual(s.search("rapport", now: now).first?.url.host(), "b.com")
    }

    func testFavoritesToggleAndList() throws {
        let s = try store()
        let url = URL(string: "https://crm.zoho.eu")!
        XCTAssertTrue(s.toggleFavorite(url: url, title: "CRM"))
        XCTAssertTrue(s.isFavorite(url))
        XCTAssertEqual(s.favorites().map(\.title), ["CRM"])
        XCTAssertFalse(s.toggleFavorite(url: url, title: "CRM"))
        XCTAssertTrue(s.favorites().isEmpty)
    }

    func testNonWebPagesAreIgnored() throws {
        let s = try store()
        s.recordVisit(url: URL(string: "about:blank")!, title: "vide", at: now)
        s.recordVisit(url: URL(string: "file:///etc/hosts")!, title: "hosts", at: now)
        XCTAssertTrue(s.search("vide", now: now).isEmpty)
        XCTAssertTrue(s.search("hosts", now: now).isEmpty)
    }

    func testTitleUpdateIsSearchable() throws {
        let s = try store()
        let url = URL(string: "https://mail.zoho.eu/inbox")!
        s.recordVisit(url: url, title: nil, at: now)
        s.updateTitle(url: url, title: "Boîte de réception")
        XCTAssertEqual(s.search("boite", now: now).first?.url, url)
    }

    /// Objectif de la phase 2 : résultats locaux en moins de 10 ms.
    func testSearchSpeedOnFiveThousandPages() throws {
        let s = try store()
        let words = ["facture", "contrat", "devis", "rapport", "client", "projet", "agenda", "compte", "export", "relance"]
        for i in 0..<5_000 {
            s.recordVisit(url: URL(string: "https://site\(i % 300).com/page/\(i)")!,
                          title: "\(words[i % 10]) \(words[(i / 10) % 10]) n°\(i)", at: now.addingTimeInterval(-Double(i) * 600))
        }
        let start = Date()
        let runs = 20
        for i in 0..<runs { _ = s.search(["fact", "contrat dev", "site12", "rapport cli"][i % 4], now: now) }
        let average = Date().timeIntervalSince(start) / Double(runs) * 1000
        XCTAssertLessThan(average, 10, "recherche moyenne : \(average) ms")
    }
}
