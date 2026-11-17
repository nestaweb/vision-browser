import XCTest
@testable import Vision_Browser

@MainActor
final class DesignSystemTests: XCTestCase {
    func testOnePigmentPerPaletteSlot() {
        XCTAssertEqual(Design.Palette.spacePigments.count, SpacesConfig.paletteCount,
                       "chaque couleur d'espace enregistrée doit avoir son pigment")
        XCTAssertEqual(Design.Palette.space(SpacesConfig.paletteCount + 1), Design.Palette.space(1), "on reboucle sur la palette")
    }

    /// « Sourdes » : ni criardes ni ternes, et lisibles en petite marque sur la salle comme sur le papier.
    func testSpaceColorsAreMutedAndReadableOnBothBackgrounds() {
        for index in 0..<SpacesConfig.paletteCount {
            let color = Design.Palette.space(index).usingColorSpace(.sRGB)!
            XCTAssertLessThan(color.saturationComponent, 0.65, "pigment \(index) trop saturé")
            XCTAssertGreaterThan(color.saturationComponent, 0.25, "pigment \(index) trop terne")
            XCTAssertGreaterThan(contrast(color, Design.Palette.house), 2.2, "pigment \(index) peu visible sur la salle")
            XCTAssertGreaterThan(contrast(color, Design.Palette.paper), 2.2, "pigment \(index) peu visible sur le papier")
        }
    }

    func testTextLevelsOnPaperAndInk() {
        XCTAssertGreaterThan(contrast(Design.Palette.ink, Design.Palette.sheet), 15, "texte principal de la barre")
        XCTAssertEqual(Design.Palette.ink(.secondary).alphaComponent, 0.55, accuracy: 0.001)
        XCTAssertEqual(Design.Palette.paper(.tertiary).alphaComponent, 0.30, accuracy: 0.001)
    }

    func testThreeDurationsAndSlowMotion() {
        XCTAssertEqual(Design.Motion.duration(.fast, slowFactor: 1), 0.14, accuracy: 0.0001)
        XCTAssertEqual(Design.Motion.duration(.medium, slowFactor: 1), 0.22, accuracy: 0.0001)
        XCTAssertEqual(Design.Motion.duration(.slow, slowFactor: 1), 0.34, accuracy: 0.0001)
        XCTAssertEqual(Design.Motion.duration(.slow, slowFactor: 4), 1.36, accuracy: 0.0001, "ralenti ×4")
        XCTAssertEqual(Design.Motion.duration(.fast, slowFactor: 0), 0.14, accuracy: 0.0001, "un facteur absurde est ignoré")
    }

    func testReduceMotionKeepsFadesOnly() {
        XCTAssertTrue(Design.Motion.allowsMovement(reduceMotion: false))
        XCTAssertFalse(Design.Motion.allowsMovement(reduceMotion: true))
    }

    func testCurveDoesNotOvershoot() {
        var points = [Float](repeating: 0, count: 2)
        let curve = Design.Motion.curve
        for index in 1...2 {
            curve.getControlPoint(at: index, values: &points)
            XCTAssertLessThanOrEqual(points[1], 1, "aucun dépassement (pas de rebond)")
        }
    }

    func testLabelIsUppercasedAndTracked() {
        let label = Design.Typography.label("Ouvert · Pro A", color: Design.Palette.ink)
        XCTAssertEqual(label.string, "OUVERT · PRO A")
        XCTAssertGreaterThan(label.attribute(.kern, at: 0, effectiveRange: nil) as? CGFloat ?? 0, 0)
    }

    // Rapport de contraste WCAG entre deux couleurs opaques.
    private func contrast(_ a: NSColor, _ b: NSColor) -> CGFloat {
        func luminance(_ c: NSColor) -> CGFloat {
            let c = c.usingColorSpace(.sRGB)!
            func channel(_ v: CGFloat) -> CGFloat { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
            return 0.2126 * channel(c.redComponent) + 0.7152 * channel(c.greenComponent) + 0.0722 * channel(c.blueComponent)
        }
        let (l1, l2) = (luminance(a), luminance(b))
        return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }
}
