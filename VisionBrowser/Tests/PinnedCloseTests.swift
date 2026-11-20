import XCTest
import WebKit
@testable import Vision_Browser

/// ⌘W sur un épinglé : l'onglet reste, sa page se ferme et il rouvrira sur son adresse épinglée.
@MainActor
final class PinnedCloseTests: XCTestCase {
    private var space: Space!

    override func setUp() async throws {
        space = Space(record: SpaceRecord(id: UUID(), name: "Test", colorIndex: 0))
    }

    override func tearDown() async throws {
        if let space { try? await WKWebsiteDataStore.remove(forIdentifier: space.id) }
    }

    func testUnloadReleasesThePageAndGoesBackToThepinnedAddress() {
        let home = URL(string: "about:blank#accueil")!
        let tab = BrowserTab(space: space, host: ExtensionHost(), url: URL(string: "about:blank#ailleurs")!, title: "Ailleurs")
        tab.isPinned = true
        tab.homeURL = home
        _ = tab.webView
        XCTAssertFalse(tab.isAsleep)

        tab.unload()
        XCTAssertTrue(tab.isAsleep, "la page est fermée")
        XCTAssertEqual(tab.url, home, "rouvre sur l'adresse épinglée")
        XCTAssertNil(tab.title, "le titre de l'ancienne page ne reste pas sur la carte")
        XCTAssertFalse(tab.webView.canGoBack, "l'historique de la page fermée est oublié")
    }

    func testUnloadOnTheHomePageKeepsItsTitle() {
        let home = URL(string: "about:blank#accueil")!
        let tab = BrowserTab(space: space, host: ExtensionHost(), url: home, title: "Accueil")
        tab.isPinned = true
        tab.homeURL = home
        tab.unload()
        XCTAssertTrue(tab.isAsleep)
        XCTAssertEqual(tab.url, home)
        XCTAssertEqual(tab.title, "Accueil", "déjà sur l'adresse épinglée : rien à oublier")
    }
}
