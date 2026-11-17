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

@MainActor
final class LoadingLineTests: XCTestCase {
    /// Le trait est toujours centré : il naît au milieu et s'élargit vers les deux bords.
    func testLineGrowsFromTheCenter() {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 2)
        let quarter = LoadingLineView.lineFrame(fraction: 0.25, in: bounds)
        XCTAssertEqual(quarter.width, 250)
        XCTAssertEqual(quarter.midX, 500, "centré")
        XCTAssertEqual(LoadingLineView.lineFrame(fraction: 0, in: bounds).midX, 500, "un point au centre")
        XCTAssertEqual(LoadingLineView.lineFrame(fraction: 1, in: bounds).width, 1000, "jusqu'aux deux bords")
        XCTAssertEqual(LoadingLineView.lineFrame(fraction: 1.4, in: bounds).width, 1000, "jamais au-delà")
        XCTAssertEqual(LoadingLineView.lineFrame(fraction: -1, in: bounds).width, 0)
    }
}

extension LoadingLineTests {
    /// En attente du serveur, le trait avance de plus en plus lentement, sans jamais dépasser 90 %.
    func testCreepSlowsDownAndStaysBelowTheEnd() {
        var fraction = LoadingLineView.minimumFraction
        var steps: [Double] = []
        for _ in 0..<200 { fraction = LoadingLineView.creep(fraction); steps.append(fraction) }
        XCTAssertGreaterThan(steps[0], LoadingLineView.minimumFraction, "il bouge dès le premier pas")
        XCTAssertLessThan(steps[1] - steps[0], steps[0] - LoadingLineView.minimumFraction, "de plus en plus lentement")
        XCTAssertLessThanOrEqual(steps.last!, 0.9)
        XCTAssertGreaterThan(steps[20], 0.6, "environ 6 s plus tard (pas de 300 ms), il a bien avancé")
    }
}
