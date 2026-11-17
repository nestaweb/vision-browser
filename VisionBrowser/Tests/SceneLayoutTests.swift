import XCTest
@testable import Vision_Browser

final class SceneLayoutTests: XCTestCase {
    private let window = CGSize(width: 1280, height: 800)

    func testStageSitsBetweenRailAndMarginAboveTheCaption() {
        let layout = SceneLayout(bounds: window, size: 1)
        let stage = layout.stage
        XCTAssertGreaterThanOrEqual(stage.minX, SceneLayout.railWidth, "la page ne passe pas sous le rail")
        XCTAssertLessThanOrEqual(stage.maxX, window.width - SceneLayout.margin)
        XCTAssertEqual(stage.minY, SceneLayout.margin)
        XCTAssertLessThan(layout.caption.maxY, layout.rowTop, "la légende tient entre la page et la rangée")
        XCTAssertEqual(stage.width / stage.height, window.width / window.height, accuracy: 0.02, "la page garde ses proportions")
    }

    func testLargerThumbnailsLeaveASmallerStage() {
        let small = SceneLayout(bounds: window, size: 0), large = SceneLayout(bounds: window, size: 2)
        XCTAssertGreaterThan(small.stage.height, large.stage.height)
        XCTAssertGreaterThan(large.thumbSize.height, small.thumbSize.height)
        XCTAssertEqual(large.thumbSize.width / large.thumbSize.height, 1.6, accuracy: 0.02, "vignettes aux proportions de la fenêtre")
    }

    func testWideWindowIsLimitedByWidth() {
        let layout = SceneLayout(bounds: CGSize(width: 900, height: 1400), size: 0)
        XCTAssertLessThanOrEqual(layout.stage.maxX, 900 - SceneLayout.margin + 1)
        XCTAssertGreaterThanOrEqual(layout.stage.minX, SceneLayout.railWidth)
        XCTAssertEqual(layout.aspect, 1.2, "proportions bornées pour une fenêtre très haute")
    }

    func testSizeIsClamped() {
        XCTAssertEqual(SceneLayout(bounds: window, size: 7).size, 2)
        XCTAssertEqual(SceneLayout(bounds: window, size: -1).size, 0)
    }

    func testStepStaysInsideTheRow() {
        XCTAssertEqual(SceneLayout.step(0, by: -1, count: 4), 0)
        XCTAssertEqual(SceneLayout.step(3, by: 1, count: 4), 3)
        XCTAssertEqual(SceneLayout.step(1, by: 1, count: 4), 2)
        XCTAssertEqual(SceneLayout.step(5, by: 0, count: 0), 0)
    }
}
