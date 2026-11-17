import XCTest
@testable import Vision_Browser

final class PageTransitionTests: XCTestCase {
    func testTabsMoveSideways() {
        XCTAssertEqual(PageTransition.between(fromSpace: 0, toSpace: 0, fromTab: 1, toTab: 3), .tab(direction: 1))
        XCTAssertEqual(PageTransition.between(fromSpace: 0, toSpace: 0, fromTab: 3, toTab: 0), .tab(direction: -1))
        XCTAssertEqual(PageTransition.tab(direction: 1).entryOffset.x, 28, "l'onglet de droite arrive par la droite")
        XCTAssertNil(PageTransition.tab(direction: 1).exitOffset, "l'ancienne page reste en place, recouverte")
    }

    func testSpacesMoveVertically() {
        XCTAssertEqual(PageTransition.between(fromSpace: 0, toSpace: 2, fromTab: 1, toTab: 0), .space(direction: 1))
        XCTAssertEqual(PageTransition.between(fromSpace: 2, toSpace: 1, fromTab: 0, toTab: 0), .space(direction: -1))
        let next = PageTransition.space(direction: 1)
        XCTAssertEqual(next.entryOffset.y, 64, "l'espace suivant arrive par le bas")
        XCTAssertEqual(next.exitOffset?.y, -32, "l'ancien recule vers le haut d'un demi-pas")
    }

    func testWrappingStepKeepsItsDirection() {
        XCTAssertEqual(PageTransition.between(fromSpace: 2, toSpace: 0, fromTab: 0, toTab: 0, spaceStep: 1), .space(direction: 1),
                       "⇧→ du dernier au premier : on continue de descendre")
        XCTAssertEqual(PageTransition.between(fromSpace: 0, toSpace: 2, fromTab: 0, toTab: 0, spaceStep: -1), .space(direction: -1))
    }

    func testNothingToAnimate() {
        XCTAssertEqual(PageTransition.between(fromSpace: nil, toSpace: 0, fromTab: nil, toTab: 0), .none, "lancement")
        XCTAssertEqual(PageTransition.between(fromSpace: 1, toSpace: 1, fromTab: nil, toTab: 2), .none, "onglet fermé")
        XCTAssertEqual(PageTransition.between(fromSpace: 1, toSpace: 1, fromTab: 2, toTab: 2), .none, "même page")
        XCTAssertEqual(PageTransition.none.entryOffset.x, 0)
    }

    func testFromAnEmptySpaceStillSlides() {
        XCTAssertEqual(PageTransition.between(fromSpace: 2, toSpace: 0, fromTab: nil, toTab: 1), .space(direction: -1))
    }
}
