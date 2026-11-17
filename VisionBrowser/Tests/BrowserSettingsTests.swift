import XCTest
@testable import Vision_Browser

final class BrowserSettingsTests: XCTestCase {
    /// Préférences jetables : les tests ne touchent jamais aux vrais réglages de l'app.
    private func settings() -> BrowserSettings {
        BrowserSettings(defaults: UserDefaults(suiteName: "vb-tests-\(UUID())")!)
    }

    func testDefaults() {
        let s = settings()
        XCTAssertEqual(s.searchEngine.id, "duckduckgo")
        XCTAssertTrue(s.searchSuggestions)
        XCTAssertEqual(s.sleepAfter, 8 * 60)
        XCTAssertEqual(s.archiveAfter, 12 * 3600)
    }

    func testChangesAreKept() {
        let s = settings()
        s.searchEngine = SearchEngine.engine(id: "qwant")
        s.searchSuggestions = false
        s.sleepAfterMinutes = 30
        s.archiveAfterHours = 48
        let again = BrowserSettings(defaults: s.defaults)
        XCTAssertEqual(again.searchEngine.name, "Qwant")
        XCTAssertFalse(again.searchSuggestions)
        XCTAssertEqual(again.sleepAfter, 30 * 60)
        XCTAssertEqual(again.archiveAfter, 48 * 3600)
    }

    func testLaunchOptionWinsForSleep() {
        let s = settings()
        s.sleepAfterMinutes = 30
        s.defaults.set(20.0, forKey: BrowserSettings.Key.sleepAfterSeconds)
        XCTAssertEqual(s.sleepAfter, 20, "l'option des essais passe avant le réglage")
    }

    func testUnknownEngineFallsBack() {
        let s = settings()
        s.defaults.set("altavista", forKey: BrowserSettings.Key.searchEngine)
        XCTAssertEqual(s.searchEngine, .fallback)
    }

    func testSearchURLsUseChosenEngine() {
        let google = SearchEngine.engine(id: "google")
        guard case .search(_, let url) = AddressInput.parse("prix c++ & co", engine: google) else { return XCTFail() }
        XCTAssertEqual(url.absoluteString, "https://www.google.com/search?q=prix%20c%2B%2B%20%26%20co")
        XCTAssertNil(SearchEngine.engine(id: "qwant").suggestURL(for: "x"), "Qwant : pas de suggestions")
    }

    func testSuggestionsStayWithChosenEngineOrAreOff() {
        let s = settings()
        s.searchEngine = SearchEngine.engine(id: "qwant")
        XCTAssertNil(SearchSuggestions.requestURL(for: "zoho", settings: s), "rien n'est envoyé à un autre moteur")
        s.searchEngine = SearchEngine.engine(id: "bing")
        XCTAssertEqual(SearchSuggestions.requestURL(for: "zoho", settings: s)?.host(), "api.bing.com")
        s.searchSuggestions = false
        XCTAssertNil(SearchSuggestions.requestURL(for: "zoho", settings: s))
    }

    func testOverviewShortcutDefaultsToCommandAtAndIsKept() {
        let s = settings()
        XCTAssertEqual(s.overviewShortcut.display, "⌘@")
        s.overviewShortcut = KeyShortcut(key: "K", modifiers: KeyShortcut.control | KeyShortcut.option)
        XCTAssertEqual(BrowserSettings(defaults: s.defaults).overviewShortcut.display, "⌃⌥⇧K")
        s.overviewShortcut = .overviewDefault
        XCTAssertNil(s.defaults.dictionary(forKey: BrowserSettings.Key.overviewShortcut), "la valeur par défaut n'est pas écrite")
    }

    func testShortcutNormalizesShiftedLettersAndRejectsBareKeys() {
        let shifted = KeyShortcut(key: "O", modifiers: KeyShortcut.command)
        XCTAssertEqual(shifted.key, "o")
        XCTAssertEqual(shifted.display, "⇧⌘O")
        XCTAssertNotNil(KeyShortcut(key: "a", modifiers: 0).problem, "une lettre seule servirait à taper")
        XCTAssertNotNil(KeyShortcut(key: "a", modifiers: KeyShortcut.shift).problem)
        XCTAssertNotNil(KeyShortcut(key: "\u{F700}", modifiers: KeyShortcut.command).problem, "flèche : pas une touche de caractère")
        XCTAssertNil(KeyShortcut.overviewDefault.problem)
    }

    func testInvalidStoredShortcutFallsBackToDefault() {
        let s = settings()
        s.defaults.set(["key": "a", "modifiers": 0], forKey: BrowserSettings.Key.overviewShortcut)
        XCTAssertEqual(s.overviewShortcut, .overviewDefault)
    }
}
