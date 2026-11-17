import XCTest
@testable import Vision_Browser

@MainActor
final class CommandBarEngineTests: XCTestCase {
    private let now = Date()
    private func engine(_ setup: (PlacesStore) -> Void = { _ in }) throws -> CommandBarEngine {
        let places = try PlacesStore(path: ":memory:")
        setup(places)
        return CommandBarEngine(places: places)
    }
    private let context = CommandBarEngine.Context(activeURL: URL(string: "https://crm.zoho.eu"), activeIsFavorite: false)

    private func tab(_ url: String, _ title: String, ago: TimeInterval = 0) -> OpenTabInfo {
        OpenTabInfo(id: UUID(), url: URL(string: url), title: title, space: "Perso", lastActivated: now.addingTimeInterval(-ago))
    }

    func testTypedAddressComesFirst() throws {
        let results = try engine().results(for: "zoho.com", tabs: [tab("https://zoho.com/a", "Zoho")], context: context)
        XCTAssertEqual(results.first?.kind, .address)
        XCTAssertEqual(results.first?.url?.absoluteString, "https://zoho.com")
    }

    func testOpenTabBeatsHistoryAndIsNotDuplicated() throws {
        let e = try engine { $0.recordVisit(url: URL(string: "https://books.zoho.eu/factures")!, title: "Factures à relancer") }
        let results = e.results(for: "factures", tabs: [tab("https://books.zoho.eu/factures", "Factures à relancer")], context: context)
        let factures = results.filter { $0.url?.absoluteString == "https://books.zoho.eu/factures" }
        XCTAssertEqual(factures.count, 1, "une page ouverte ne doit apparaître qu'une fois")
        if case .openTab = factures.first?.kind {} else { XCTFail("l'onglet ouvert doit l'emporter sur l'historique") }
        XCTAssertEqual(factures.first?.actionLabel, "Basculer")
    }

    func testFavoriteHasItsOwnKind() throws {
        let e = try engine { $0.toggleFavorite(url: URL(string: "https://github.com/nestaweb")!, title: "nestaweb") }
        let result = e.results(for: "nesta", tabs: [], context: context).first { $0.url?.host() == "github.com" }
        XCTAssertEqual(result?.kind, .favorite)
        XCTAssertTrue(result?.isFavorite ?? false)
    }

    func testFreeTextOffersSearchBelowStrongMatches() throws {
        let e = try engine { places in
            for _ in 0..<5 { places.recordVisit(url: URL(string: "https://github.com/nestaweb/vision-browser")!, title: "vision-browser") }
        }
        let results = e.results(for: "github vision", tabs: [], context: context)
        XCTAssertEqual(results.first?.kind, .history, "une page très visitée passe devant la recherche web")
        XCTAssertTrue(results.contains { $0.kind == .search })
    }

    func testCommandsMatchByPrefix() throws {
        let results = try engine().results(for: "copi", tabs: [], context: context)
        XCTAssertTrue(results.contains { $0.kind == .command(.copyAddress) })
        let favorite = try engine().results(for: "favo", tabs: [], context: context)
        XCTAssertEqual(favorite.first { if case .command = $0.kind { true } else { false } }?.title, "Ajouter aux favoris")
    }

    func testCommandsNeedAnActivePage() throws {
        let results = try engine().results(for: "copier", tabs: [], context: .init(activeURL: nil, activeIsFavorite: false))
        XCTAssertFalse(results.contains { if case .command = $0.kind { true } else { false } })
    }

    func testSuggestionsComeLastAndWithoutDuplicates() throws {
        let results = try engine().results(for: "swift", tabs: [], context: context, suggestions: ["swift", "swiftui", "swift concurrency"])
        XCTAssertEqual(results.first?.kind, .search)
        XCTAssertEqual(results.filter { $0.kind == .suggestion }.map(\.title), ["swiftui", "swift concurrency"])
    }

    func testEmptyQueryShowsRecentTabsThenFavorites() throws {
        let e = try engine { $0.toggleFavorite(url: URL(string: "https://kagi.com")!, title: "Kagi") }
        let results = e.results(for: "  ", tabs: [tab("https://a.com", "A", ago: 60), tab("https://b.com", "B", ago: 5)], context: context)
        XCTAssertEqual(results.map(\.title), ["B", "A", "Kagi"])
    }

    func testAccentInsensitiveTabMatch() throws {
        let results = try engine().results(for: "boite reception", tabs: [tab("https://mail.zoho.eu", "Boîte de réception (12)")], context: context)
        XCTAssertTrue(results.contains { if case .openTab = $0.kind { true } else { false } })
    }

    func testSamePageWithDifferentParametersAppearsOnce() throws {
        let e = try engine { places in
            places.recordVisit(url: URL(string: "https://duckduckgo.com/?q=swift%20concurrency")!, title: "swift concurrency at DuckDuckGo")
            places.recordVisit(url: URL(string: "https://duckduckgo.com/?q=swift+concurrency&ia=web")!, title: "swift concurrency at DuckDuckGo")
            places.toggleFavorite(url: URL(string: "https://duckduckgo.com/?q=swift%20concurrency")!, title: "swift concurrency at DuckDuckGo")
        }
        let pages = e.results(for: "concurr", tabs: [], context: context).filter { $0.title == "swift concurrency at DuckDuckGo" }
        XCTAssertEqual(pages.count, 1)
        XCTAssertEqual(pages.first?.kind, .favorite, "la version en favori est gardée")
    }

    func testSpaceCommands() throws {
        let perso = UUID(), proB = UUID()
        let spaces = CommandBarEngine.Context(activeURL: URL(string: "https://crm.zoho.eu/home"), activeIsFavorite: false,
                                              spaces: [.init(id: perso, name: "Perso"), .init(id: proB, name: "Pro B")],
                                              currentSpaceID: perso)
        let e = try engine()
        let commandKinds = { (query: String) in e.results(for: query, tabs: [], context: spaces).compactMap { result -> CommandResult.CommandID? in
            if case .command(let id) = result.kind { return id }; return nil } }
        XCTAssertTrue(commandKinds("nouvel esp").contains(.newSpace))
        XCTAssertTrue(commandKinds("aller pro").contains(.switchSpace(proB)))
        XCTAssertFalse(commandKinds("aller perso").contains(.switchSpace(perso)), "on ne propose pas d'aller dans l'espace actuel")
        XCTAssertTrue(commandKinds("envoyer pro b").contains(.moveTab(proB)))
        XCTAssertTrue(commandKinds("toujours").contains(.routeHostHere))
        var routed = spaces
        routed.routedSpaceForActiveHost = perso
        XCTAssertFalse(e.results(for: "toujours", tabs: [], context: routed).contains { $0.kind == .command(.routeHostHere) },
                       "règle déjà en place : rien à proposer")
    }

    func testSpaceCommandsWithoutActivePage() throws {
        let ctx = CommandBarEngine.Context(activeURL: nil, activeIsFavorite: false, spaces: [.init(id: UUID(), name: "Perso")], currentSpaceID: nil)
        let results = try engine().results(for: "nouvel", tabs: [], context: ctx)
        XCTAssertTrue(results.contains { $0.kind == .command(.newSpace) }, "créer un espace n'a pas besoin de page ouverte")
    }

    func testSuggestionParsing() {
        XCTAssertEqual(SearchSuggestions.parse(Data(#"["swi",["swift","swiftui"]]"#.utf8)), ["swift", "swiftui"])
        XCTAssertEqual(SearchSuggestions.parse(Data("{}".utf8)), [])
        XCTAssertEqual(SearchSuggestions.requestURL(for: "c++ & co")?.absoluteString, "https://duckduckgo.com/ac/?q=c++%20%26%20co&type=list")
    }
}
