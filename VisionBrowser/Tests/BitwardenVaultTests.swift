import XCTest
@testable import Vision_Browser

final class BitwardenVaultTests: XCTestCase {
    /// Extrait fidèle au format de `bw list items` (valeurs fictives).
    private let itemsJSON = Data("""
    [
      {"object":"item","id":"a1","organizationId":null,"folderId":"f-proa","type":1,"name":"Zoho","favorite":false,
       "login":{"uris":[{"match":null,"uri":"https://accounts.zoho.eu"}],"username":"compta@exemple-a.fr","password":"secret-a","totp":null}},
      {"object":"item","id":"b2","organizationId":null,"folderId":"f-prob","type":1,"name":"Zoho","favorite":true,
       "login":{"uris":[{"match":null,"uri":"accounts.zoho.eu"}],"username":"direction@exemple-b.fr","password":"secret-b"}},
      {"object":"item","id":"c3","folderId":null,"type":1,"name":"GitHub",
       "login":{"uris":[{"uri":"https://github.com/login"}],"username":"nestaweb","password":"x"}},
      {"object":"item","id":"n4","folderId":null,"type":2,"name":"Note sécurisée","secureNote":{"type":0}},
      {"object":"item","id":"d5","folderId":null,"type":1,"name":"Ancien","deletedDate":"2026-01-01T00:00:00Z",
       "login":{"uris":[],"username":"old"}}
    ]
    """.utf8)
    private let foldersJSON = Data("""
    [{"object":"folder","id":"f-proa","name":"Pro A"},{"object":"folder","id":"f-prob","name":"pro b"},{"object":"folder","id":null,"name":"No Folder"}]
    """.utf8)

    private let perso = SpacesConfig.defaultSpaceID, proA = UUID(), proB = UUID()
    private var config: SpacesConfig {
        SpacesConfig(spaces: [.init(id: perso, name: "Perso", colorIndex: 0), .init(id: proA, name: "Pro A", colorIndex: 1),
                              .init(id: proB, name: "Pro B", colorIndex: 2)],
                     rules: [.init(host: "github.com", spaceID: perso)])
    }
    private func vault() throws -> BitwardenVault {
        BitwardenVault(items: try BitwardenJSON.items(itemsJSON), folders: try BitwardenJSON.folders(foldersJSON))
    }

    func testParsingKeepsLoginsOnlyAndNoPasswords() throws {
        let items = try BitwardenJSON.items(itemsJSON)
        XCTAssertEqual(items.map(\.id), ["a1", "b2", "c3"], "notes et corbeille exclues")
        XCTAssertEqual(items[1].loginURL?.absoluteString, "https://accounts.zoho.eu", "adresse sans schéma complétée")
        XCTAssertFalse(String(describing: items).contains("secret"), "le mot de passe n'est jamais lu dans la liste")
        XCTAssertEqual(try BitwardenJSON.folders(foldersJSON).map(\.name), ["Pro A", "pro b"])
    }

    func testStatusAndCredentials() {
        XCTAssertEqual(BitwardenJSON.status(Data(#"{"serverUrl":null,"status":"unauthenticated"}"#.utf8)), .unauthenticated)
        XCTAssertEqual(BitwardenJSON.status(Data(#"{"status":"locked","userEmail":"a@b.fr"}"#.utf8)), .locked(email: "a@b.fr"))
        XCTAssertEqual(BitwardenJSON.status(Data(#"{"status":"unlocked","userEmail":"a@b.fr"}"#.utf8)), .unlocked(email: "a@b.fr"))
        let creds = BitwardenJSON.credentials(Data(#"{"login":{"username":"u","password":"p"}}"#.utf8))
        XCTAssertEqual(creds.username, "u")
        XCTAssertEqual(creds.password, "p")
    }

    func testZohoGivesBothAccountsEachInItsSpace() throws {
        let results = try vault().search("zoho", config: config, currentSpaceID: proB)
        XCTAssertEqual(results.map(\.item.username), ["direction@exemple-b.fr", "compta@exemple-a.fr"], "l'espace affiché passe devant")
        XCTAssertEqual(results.map(\.spaceName), ["Pro B", "Pro A"], "dossier du même nom (sans tenir compte de la casse)")
    }

    func testExplicitFolderLinkWinsAndRoutingIsTheFallback() throws {
        var linked = config
        linked.linkBitwardenFolder("f-proa", to: perso)
        let v = try vault()
        XCTAssertEqual(v.spaceID(for: v.items[0], config: linked), perso, "lien explicite")
        XCTAssertEqual(v.spaceID(for: v.items[2], config: linked), perso, "pas de dossier : règle de routage github.com")
        linked.linkBitwardenFolder("f-proa", to: proB)
        XCTAssertNil(linked.space(perso)?.bitwardenFolderID, "un dossier n'est relié qu'à un espace")
    }

    func testSearchMatchesUsernameAndHostWithoutAccents() throws {
        let v = try vault()
        XCTAssertEqual(v.search("direction", config: config, currentSpaceID: nil).map(\.item.id), ["b2"])
        XCTAssertEqual(v.search("github.com", config: config, currentSpaceID: nil).map(\.item.id), ["c3"])
        XCTAssertTrue(v.search("z", config: config, currentSpaceID: nil).isEmpty, "une lettre ne suffit pas")
    }

    func testFillOnlyOnTheRegisteredSite() throws {
        let zoho = try vault().items[0]
        XCTAssertTrue(BitwardenVault.pageMatches(URL(string: "https://accounts.zoho.eu/signin?x=1"), item: zoho))
        XCTAssertTrue(BitwardenVault.pageMatches(URL(string: "https://crm.zoho.eu"), item: zoho), "même site")
        XCTAssertFalse(BitwardenVault.pageMatches(URL(string: "https://zoho.eu.hameconnage.com"), item: zoho))
        XCTAssertFalse(BitwardenVault.pageMatches(nil, item: zoho))
    }
}
