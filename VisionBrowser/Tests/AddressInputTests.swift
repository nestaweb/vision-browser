import XCTest
@testable import Vision_Browser

final class AddressInputTests: XCTestCase {
    func testFullURLIsKeptAsIs() {
        XCTAssertEqual(AddressInput.parse("https://crm.zoho.eu/crm/tab/Home")?.url.absoluteString,
                       "https://crm.zoho.eu/crm/tab/Home")
    }

    func testBareDomainGetsHTTPS() {
        XCTAssertEqual(AddressInput.parse("zoho.com"), .url(URL(string: "https://zoho.com")!))
        XCTAssertEqual(AddressInput.parse("  github.com/nestaweb  ")?.url.absoluteString, "https://github.com/nestaweb")
    }

    func testLocalhostAndIPUseHTTP() {
        XCTAssertEqual(AddressInput.parse("localhost:3000")?.url.absoluteString, "http://localhost:3000")
        XCTAssertEqual(AddressInput.parse("192.168.1.10")?.url.absoluteString, "http://192.168.1.10")
        XCTAssertEqual(AddressInput.parse("monapp.test/login")?.url.absoluteString, "http://monapp.test/login")
    }

    func testFreeTextIsASearch() {
        guard case .search(let query, let url) = AddressInput.parse("export csv zoho", engine: .fallback) else {
            return XCTFail("devrait être une recherche")
        }
        XCTAssertEqual(query, "export csv zoho")
        XCTAssertEqual(url.absoluteString, "https://duckduckgo.com/?q=export%20csv%20zoho")
    }

    func testSingleWordAndBadTLDAreSearches() {
        if case .url = AddressInput.parse("zoho") { XCTFail("un mot seul est une recherche") }
        if case .url = AddressInput.parse("version 2.0") { XCTFail("du texte avec espace est une recherche") }
        if case .url = AddressInput.parse("fichier.1") { XCTFail("une extension numérique n'est pas un domaine") }
    }

    func testSpecialCharactersAreEncodedInSearch() {
        XCTAssertEqual(AddressInput.parse("c++ & swift?")?.url.absoluteString,
                       "https://duckduckgo.com/?q=c%2B%2B%20%26%20swift%3F")
    }

    func testEmptyInputGivesNil() {
        XCTAssertNil(AddressInput.parse("   "))
    }
}
