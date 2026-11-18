import XCTest
import Network
import WebKit
@testable import Vision_Browser

/// Une adresse tapée sans schéma part en HTTPS et se rabat sur HTTP quand le site n'a pas de HTTPS
/// (cas réel : un serveur de préproduction qui n'écoute que sur le port 80).
@MainActor
final class HTTPFallbackTests: XCTestCase {
    // MARK: Ce qui ouvre droit au repli

    func testOnlyAddressesTypedWithoutSchemeFallBack() {
        XCTAssertEqual(AddressInput.httpFallback(forTyped: " preprod.exemple.com/dashboard "),
                       URL(string: "http://preprod.exemple.com/dashboard"))
        XCTAssertNil(AddressInput.httpFallback(forTyped: "https://preprod.exemple.com"), "https tapé : pas de repli")
        XCTAssertNil(AddressInput.httpFallback(forTyped: "HTTPS://exemple.com"))
        XCTAssertNil(AddressInput.httpFallback(forTyped: "http://exemple.com"), "déjà en http")
        XCTAssertNil(AddressInput.httpFallback(forTyped: "localhost:3000"), "déjà en http")
        XCTAssertNil(AddressInput.httpFallback(forTyped: "recette crêpes"), "une recherche n'a pas de repli")
    }

    func testOnlyConnectionAndCertificateFailuresMeanNoHTTPS() {
        let error = { (code: Int) in NSError(domain: NSURLErrorDomain, code: code) }
        XCTAssertTrue(BrowserTab.meansNoHTTPS(error(NSURLErrorTimedOut)))
        XCTAssertTrue(BrowserTab.meansNoHTTPS(error(NSURLErrorCannotConnectToHost)))
        XCTAssertTrue(BrowserTab.meansNoHTTPS(error(NSURLErrorSecureConnectionFailed)))
        XCTAssertTrue(BrowserTab.meansNoHTTPS(error(NSURLErrorServerCertificateUntrusted)))
        XCTAssertFalse(BrowserTab.meansNoHTTPS(error(NSURLErrorCannotFindHost)), "adresse introuvable : HTTP n'y changerait rien")
        XCTAssertFalse(BrowserTab.meansNoHTTPS(error(NSURLErrorCancelled)), "navigation annulée par l'utilisateur")
        XCTAssertFalse(BrowserTab.meansNoHTTPS(NSError(domain: "WebKitErrorDomain", code: 102)))
    }

    // MARK: De bout en bout, avec une vraie vue web

    private var space: Space!
    private var host: ExtensionHost!
    private var listeners: [NWListener] = []

    override func setUp() async throws {
        space = Space(record: SpaceRecord(id: UUID(), name: "Test", colorIndex: 0))
        host = ExtensionHost()
    }

    override func tearDown() async throws {
        listeners.forEach { $0.cancel() }
        if let space { try? await WKWebsiteDataStore.remove(forIdentifier: space.id) }
    }

    /// Port HTTPS fermé (connexion refusée) : repli immédiat sur la version HTTP.
    func testClosedHTTPSPortFallsBackToHTTP() async throws {
        let http = try await startServer(.answer)
        let tab = BrowserTab(space: space, host: host)
        tab.load(URL(string: "https://127.0.0.1:\(try closedPort())/")!, httpFallback: URL(string: "http://127.0.0.1:\(http)/")!)
        try await waitForTitle(of: tab, timeout: 3)
        XCTAssertEqual(tab.webView.url?.scheme, "http")
    }

    /// Port HTTPS qui accepte la connexion mais ne répond jamais (cas du serveur de préproduction, où le pare-feu
    /// laisse le délai s'écouler) : repli au bout de `httpsPatience`, sans attendre la minute de WebKit.
    func testSilentHTTPSFallsBackAfterThePatienceDelay() async throws {
        let http = try await startServer(.answer)
        let silent = try await startServer(.silent)
        let tab = BrowserTab(space: space, host: host)
        let start = ContinuousClock.now
        tab.load(URL(string: "https://127.0.0.1:\(silent)/")!, httpFallback: URL(string: "http://127.0.0.1:\(http)/")!)
        try await waitForTitle(of: tab, timeout: 10)
        XCTAssertEqual(tab.webView.url?.scheme, "http")
        XCTAssertGreaterThanOrEqual(ContinuousClock.now - start, BrowserTab.httpsPatience)
    }

    /// Sans repli demandé (lien, favori, `https://` tapé), un HTTPS en échec n'est jamais rétrogradé.
    func testWithoutFallbackHTTPSIsNeverDowngraded() async throws {
        let http = try await startServer(.answer)
        let tab = BrowserTab(space: space, host: host)
        tab.load(URL(string: "https://127.0.0.1:\(try closedPort())/")!)
        try await Task.sleep(for: .seconds(2))
        XCTAssertNotEqual(tab.webView.url?.absoluteString, "http://127.0.0.1:\(http)/")
        XCTAssertNotEqual(tab.webView.title, "repli")
    }

    // MARK: Outils

    private enum Behavior { case answer, silent }

    /// Petit serveur local : `.answer` répond une page HTTP, `.silent` accepte la connexion et ne dit rien.
    private func startServer(_ behavior: Behavior) async throws -> UInt16 {
        let listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            guard behavior == .answer else { return }
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { _, _, _, _ in
                let body = "<!doctype html><title>repli</title><p>ok"
                let reply = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                connection.send(content: Data(reply.utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        listeners.append(listener)
        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: listener.stateUpdateHandler = nil; continuation.resume(returning: listener.port!.rawValue)
                case .failed(let error): listener.stateUpdateHandler = nil; continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: .global())
        }
    }

    /// Un port libre, sur lequel personne n'écoute (la connexion y est refusée).
    private func closedPort() throws -> UInt16 {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        defer { close(socket) }
        var address = sockaddr_in(sin_len: UInt8(MemoryLayout<sockaddr_in>.size), sin_family: sa_family_t(AF_INET),
                                  sin_port: 0, sin_addr: in_addr(s_addr: inet_addr("127.0.0.1")), sin_zero: (0, 0, 0, 0, 0, 0, 0, 0))
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        try withUnsafeMutablePointer(to: &address) { pointer in
            try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                guard Darwin.bind(socket, $0, length) == 0, getsockname(socket, $0, &length) == 0 else { throw URLError(.cannotConnectToHost) }
            }
        }
        return UInt16(bigEndian: address.sin_port)
    }

    private func waitForTitle(of tab: BrowserTab, timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while tab.webView.title != "repli" {
            guard Date() < deadline else {
                return XCTFail("pas de repli HTTP (adresse : \(tab.webView.url?.absoluteString ?? "-"))")
            }
            try await Task.sleep(for: .milliseconds(100))
        }
    }
}
