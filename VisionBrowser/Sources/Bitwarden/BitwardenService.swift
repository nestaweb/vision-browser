import AppKit
import LocalAuthentication

/// Lance la CLI officielle `bw`, une commande à la fois. **Jamais `bw serve`** : un serveur local exposerait
/// le coffre à toutes les apps du Mac.
struct BitwardenCLI: Sendable {
    let executable: URL

    enum Failure: LocalizedError {
        case command(String)
        var errorDescription: String? {
            switch self { case .command(let message): message }
        }
    }

    /// Emplacements habituels (Homebrew Apple Silicon, Homebrew Intel, npm).
    static func locate() -> BitwardenCLI? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = ["/opt/homebrew/bin/bw", "/usr/local/bin/bw", "\(home)/.npm-global/bin/bw"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map { BitwardenCLI(executable: URL(fileURLWithPath: $0)) }
    }

    /// - Parameters:
    ///   - session: clé de session (`BW_SESSION`), transmise par l'environnement.
    ///   - environment: variables supplémentaires (le mot de passe maître passe ici, jamais en argument :
    ///     les arguments sont visibles dans la liste des processus).
    func run(_ arguments: [String], session: String? = nil, environment extra: [String: String] = [:]) async throws -> Data {
        let executable = executable
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = executable
                process.arguments = arguments + ["--nointeraction"]
                var environment = [
                    "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
                    "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
                    "BW_NOINTERACTION": "true",
                ]
                if let session { environment["BW_SESSION"] = session }
                environment.merge(extra) { _, new in new }
                process.environment = environment
                let output = Pipe(), errors = Pipe()
                process.standardOutput = output
                process.standardError = errors
                process.standardInput = FileHandle.nullDevice
                do { try process.run() } catch { return continuation.resume(throwing: error) }
                let data = output.fileHandleForReading.readDataToEndOfFile()
                let message = errors.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                if process.terminationStatus == 0 {
                    continuation.resume(returning: data)
                } else {
                    let text = String(decoding: message.isEmpty ? data : message, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(throwing: Failure.command(text.isEmpty ? "bw a échoué (code \(process.terminationStatus))" : text))
                }
            }
        }
    }
}

/// Le coffre Bitwarden vu par l'app (recherche Cmd+T, remplissage, espaces).
///
/// La clé de session reste **en mémoire** (jamais sur disque) et la CLI est verrouillée à la fermeture.
/// Seuls nom, identifiant, adresses et dossier sont gardés ; le mot de passe est demandé à `bw` au dernier moment.
@MainActor
final class BitwardenService {
    static let shared = BitwardenService(demo: UserDefaults.standard.bool(forKey: "VBBitwardenDemo"))

    private(set) var status: BitwardenStatus = .notInstalled
    private(set) var vault = BitwardenVault()
    private(set) var isBusy = false
    let isDemo: Bool
    private let cli: BitwardenCLI?
    private var session: String?
    private var lastAuthentication: Date?
    /// Appelé quand le statut ou le contenu change (barre Cmd+T, menu Espaces).
    var onChange: (() -> Void)?

    init(demo: Bool) {
        isDemo = demo
        cli = demo ? nil : BitwardenCLI.locate()
        if demo {
            status = .unlocked(email: "démo")
            vault = Self.demoVault
        }
    }

    var isUnlocked: Bool { if case .unlocked = status { true } else { false } }

    func refreshStatus() async {
        guard !isDemo else { return }
        guard let cli else { return update(.notInstalled) }
        let data = try? await cli.run(["status"], session: session)
        update(data.map(BitwardenJSON.status) ?? .unauthenticated)
    }

    /// Déverrouille avec le mot de passe maître (passé à `bw` par variable d'environnement), puis charge la liste.
    func unlock(password: String) async throws {
        guard !isDemo else { return }
        guard let cli else { throw BitwardenCLI.Failure.command("La CLI Bitwarden (bw) est introuvable.") }
        isBusy = true
        defer { isBusy = false }
        let data = try await cli.run(["unlock", "--passwordenv", "VB_BW_PASSWORD", "--raw"], environment: ["VB_BW_PASSWORD": password])
        let key = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw BitwardenCLI.Failure.command("Bitwarden n'a pas renvoyé de clé de session.") }
        session = key
        try await load()
        // Synchronisation avec le serveur en arrière-plan, puis rechargement.
        Task { [weak self] in
            guard let self, let session = self.session else { return }
            _ = try? await cli.run(["sync"], session: session)
            try? await self.load()
        }
    }

    func load() async throws {
        guard !isDemo, let cli, let session else { return }
        async let items = cli.run(["list", "items"], session: session)
        async let folders = cli.run(["list", "folders"], session: session)
        vault = BitwardenVault(items: try BitwardenJSON.items(try await items), folders: try BitwardenJSON.folders(try await folders))
        await refreshStatus()
        onChange?()
    }

    /// Verrouille : oublie la clé de session et la liste, et verrouille la CLI.
    func lock() {
        guard !isDemo else { return }
        let hadSession = session != nil
        session = nil
        vault = BitwardenVault()
        lastAuthentication = nil
        if case .unlocked(let email) = status { status = .locked(email: email) }
        onChange?()
        if hadSession, let cli { Task { _ = try? await cli.run(["lock"]) } }
    }

    /// À la fermeture de l'app : verrouillage synchrone (court), pour ne laisser aucune session ouverte.
    func lockBeforeQuit() {
        guard !isDemo, session != nil, let cli else { return }
        session = nil
        let process = Process()
        process.executableURL = cli.executable
        process.arguments = ["lock", "--nointeraction"]
        process.environment = ["PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
                               "HOME": FileManager.default.homeDirectoryForCurrentUser.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        let deadline = Date().addingTimeInterval(3)
        while process.isRunning && Date() < deadline { usleep(50_000) }
    }

    /// Identifiant et mot de passe d'un élément, demandés à `bw` au moment de s'en servir.
    func credentials(for id: String) async throws -> (username: String?, password: String?) {
        if isDemo { return Self.demoCredentials[id] ?? (nil, nil) }
        guard let cli, let session else { throw BitwardenCLI.Failure.command("Bitwarden est verrouillé.") }
        return BitwardenJSON.credentials(try await cli.run(["get", "item", id], session: session))
    }

    /// Touch ID (ou mot de passe du Mac) avant d'utiliser un mot de passe ; valable 5 min.
    func authenticate(reason: String) async -> Bool {
        if isDemo { return true }  // mode démo : comptes fictifs, pas de vrai secret
        if let last = lastAuthentication, Date().timeIntervalSince(last) < 300 { return true }
        let context = LAContext()
        context.localizedFallbackTitle = "Utiliser le mot de passe"
        guard (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) == true else { return false }
        lastAuthentication = Date()
        return true
    }

    private func update(_ newStatus: BitwardenStatus) {
        if newStatus == .unauthenticated || newStatus == .notInstalled { session = nil; vault = BitwardenVault() }
        guard newStatus != status else { return }
        status = newStatus
        onChange?()
    }

    // MARK: Mode démo (`-VBBitwardenDemo YES`) : comptes fictifs et page de connexion locale

    private static let demoVault = BitwardenVault(
        items: [
            BitwardenItem(id: "demo-a", name: "Démo Zoho", username: "compta@exemple-a.test",
                          uris: [URL(string: "http://localhost:8765/login.html")!], folderID: "demo-proa"),
            BitwardenItem(id: "demo-b", name: "Démo Zoho", username: "direction@exemple-b.test",
                          uris: [URL(string: "http://localhost:8765/login.html")!], folderID: "demo-prob", favorite: true),
        ],
        folders: [BitwardenFolder(id: "demo-proa", name: "Pro A"), BitwardenFolder(id: "demo-prob", name: "Pro B")])

    private static let demoCredentials: [String: (String?, String?)] = [
        "demo-a": ("compta@exemple-a.test", "Demo-A-mot-de-passe"),
        "demo-b": ("direction@exemple-b.test", "Demo-B-mot-de-passe"),
    ]
}

/// Remplit un formulaire de connexion, depuis le monde isolé (invisible pour la page).
/// Gère les formulaires en plusieurs étapes (e-mail, puis mot de passe) ; n'envoie **jamais** le formulaire.
enum LoginFiller {
    /// Corps d'une fonction asynchrone ; `username`, `password` et `site` sont passés en arguments,
    /// jamais collés dans le code (pas d'injection possible).
    static let script = """
    const onSite = () => location.hostname === site || location.hostname.endsWith('.' + site);
    if (!onSite()) return 'wrong-site';
    const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
    const fill = (el, value) => {
      el.focus();
      setter.call(el, value);
      el.dispatchEvent(new Event('input', { bubbles: true }));
      el.dispatchEvent(new Event('change', { bubbles: true }));
    };
    const visible = el => !!(el.offsetWidth || el.offsetHeight || el.getClientRects().length) && !el.disabled && !el.readOnly;
    const userSelector = 'input[autocomplete~="username"], input[type="email"], input[name*="user" i], input[name*="login" i], ' +
                         'input[name*="mail" i], input[id*="user" i], input[id*="login" i], input[id*="mail" i], input[type="text"]';
    let userDone = !username, passDone = !password;
    const attempt = () => {
      if (!onSite()) return true;
      const pass = [...document.querySelectorAll('input[type="password"]')].find(visible);
      if (!userDone) {
        const user = [...document.querySelectorAll(userSelector)].find(visible);
        if (user) { if (!user.value) fill(user, username); userDone = true; }
      }
      if (!passDone && pass) { fill(pass, password); passDone = true; }
      return userDone && passDone;
    };
    if (attempt()) return 'filled';
    return await new Promise(resolve => {
      const observer = new MutationObserver(() => { if (attempt()) { observer.disconnect(); resolve('filled'); } });
      observer.observe(document.documentElement, { subtree: true, childList: true, attributes: true });
      setTimeout(() => { observer.disconnect(); resolve(userDone ? 'partial' : 'nothing'); }, 120000);
    });
    """
}
