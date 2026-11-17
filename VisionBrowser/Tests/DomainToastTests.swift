import XCTest
@testable import Vision_Browser

@MainActor
final class DomainToastTests: XCTestCase {
    /// Symboles monochromes ; seuls les avertissements gardent une couleur, la brique sourde de la palette.
    func testOnlyWarningsKeepAColor() {
        XCTAssertEqual(DomainToastView.symbolColor(for: .systemRed), Design.Palette.space(7), "site non sécurisé")
        XCTAssertEqual(DomainToastView.symbolColor(for: .systemOrange), Design.Palette.space(7), "échec, avertissement")
        for tint in [NSColor.systemBlue, .systemGreen, .systemPurple, .systemYellow, Design.Palette.space(1)] {
            XCTAssertEqual(DomainToastView.symbolColor(for: tint), Design.Palette.ink(.secondary))
        }
    }
}
