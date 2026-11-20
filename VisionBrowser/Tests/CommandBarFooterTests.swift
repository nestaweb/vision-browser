import XCTest
@testable import Vision_Browser

/// Le bas de la barre Cmd+T dit ce que fait chaque touche pour la ligne choisie.
@MainActor
final class CommandBarFooterTests: XCTestCase {
    func testBitwardenRowsSayEnterCopiesThePassword() {
        let row = CommandResult(kind: .bitwarden(id: "1", space: "Travail"), title: "GitHub", subtitle: "", url: nil, score: 1)
        let keys = CommandBarView.footerEntries(newTab: true, for: row)
        XCTAssertEqual(keys.first?.0, "↩")
        XCTAssertEqual(keys.first?.1, "copier le mot de passe")
        XCTAssertTrue(keys.contains { $0 == ("⌘↩", "remplir la page") })
    }

    func testOtherRowsKeepTheUsualKeys() {
        let row = CommandResult(kind: .address, title: "exemple.fr", subtitle: "", url: URL(string: "https://exemple.fr"), score: 1)
        XCTAssertEqual(CommandBarView.footerEntries(newTab: true, for: row).first?.1, "ouvrir")
        XCTAssertEqual(CommandBarView.footerEntries(newTab: false, for: nil).first?.1, "ouvrir ici")
    }
}
