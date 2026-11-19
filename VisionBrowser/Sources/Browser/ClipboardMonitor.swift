import AppKit
import LocalAuthentication
import WebKit

/// Historique du presse-papier (F3) : **lecture sur événement uniquement**, jamais en boucle.
///
/// Déclencheurs : copie dans une page (script `CopyRelay`), `Cmd+C` / `Cmd+X` dans l'app, retour de l'app au
/// premier plan, fermeture du popup Bitwarden. À chaque fois on compare `changeCount` : le contenu n'est lu
/// que s'il a changé.
@MainActor
final class ClipboardMonitor {
    static let shared = ClipboardMonitor(store: ClipboardStore.openDefault())

    private(set) var history: ClipboardHistory
    private let store: ClipboardStore?
    private var lastChangeCount = NSPasteboard.general.changeCount
    /// Écritures faites par l'app elle-même (recoller un élément) : à ne pas capturer.
    private var ownChangeCounts: Set<Int> = []
    /// Dernière autre app passée au premier plan : l'origine probable d'une copie faite ailleurs.
    private var lastOtherApp: String?
    private var bitwardenPopupOpen = false
    private var observers: [NSObjectProtocol] = []
    /// Appelé quand l'historique change (barre Cmd+T ouverte).
    var onChange: (() -> Void)?

    init(store: ClipboardStore?) {
        self.store = store
        history = ClipboardHistory(items: store?.load() ?? [])
        // Des secrets gardés par une version précédente (règles moins strictes) quittent le disque.
        let reclassified = history.reclassifySecrets()
        if !reclassified.isEmpty { store?.delete(reclassified) }
    }

    func start() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { ClipboardMonitor.shared.check(source: ClipboardMonitor.shared.lastOtherApp) }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let name = app?.bundleIdentifier == Bundle.main.bundleIdentifier ? nil : app?.localizedName
            MainActor.assumeIsolated { if let name { ClipboardMonitor.shared.lastOtherApp = name } }
        })
    }

    /// Vérifie le presse-papier après une copie (laisse le temps à la page ou à l'app d'y écrire).
    /// - Parameter fromExtension: la copie vient d'un cadre de l'extension (menu Bitwarden dans un champ).
    func checkSoon(source: String?, fromExtension: Bool = false) {
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            self?.check(source: source, fromExtension: fromExtension)
        }
    }

    func check(source: String?, fromExtension: Bool = false) {
        let pasteboard = NSPasteboard.general
        let count = pasteboard.changeCount
        guard count != lastChangeCount else { return }
        lastChangeCount = count
        guard !ownChangeCounts.contains(count) else { return }
        let content = PasteboardContent(
            types: pasteboard.types?.map(\.rawValue) ?? [],
            string: pasteboard.string(forType: .string),
            declaredSource: pasteboard.string(forType: NSPasteboard.PasteboardType("org.nspasteboard.source")).flatMap(Self.appName))
        guard let item = ClipboardPolicy.classify(content, fromBitwarden: bitwardenPopupOpen || fromExtension, source: source) else { return }
        let kept = history.add(item)
        store?.save(kept)
        store?.trim()
        onChange?()
    }

    // MARK: Popup Bitwarden

    func bitwardenPopupDidOpen() {
        check(source: nil)  // ce qui était là avant n'est pas attribué à Bitwarden
        bitwardenPopupOpen = true
    }

    func bitwardenPopupDidClose() {
        check(source: "Bitwarden")
        bitwardenPopupOpen = false
    }

    // MARK: Expiration

    func purge(now: Date = Date()) {
        let removed = history.purge(now: now)
        guard !removed.isEmpty else { return }
        store?.delete(removed)
        onChange?()
    }

    // MARK: Recoller

    /// Met un élément dans le presse-papier. Un secret est marqué confidentiel et temporaire :
    /// les gestionnaires de presse-papier ne le gardent pas.
    func write(_ item: ClipboardItem) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if item.kind == .secret {
            pasteboard.declareTypes([.string, .init(ClipboardPolicy.concealedType), .init(ClipboardPolicy.transientType)], owner: nil)
            pasteboard.setString("", forType: .init(ClipboardPolicy.concealedType))
            pasteboard.setString("", forType: .init(ClipboardPolicy.transientType))
        }
        pasteboard.setString(item.text, forType: .string)
        markOwn()
    }

    /// Recolle un élément dans le champ actif de la page, puis, pour un secret, remet le presse-papier d'avant.
    func paste(_ item: ClipboardItem) {
        let previous = item.kind == .secret ? NSPasteboard.general.string(forType: .string) : nil
        write(item)
        NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
        guard item.kind == .secret else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            if let previous { pasteboard.setString(previous, forType: .string) }
            self?.markOwn()
        }
    }

    /// Ajoute à l'historique un élément que l'app a elle-même copié (mot de passe Bitwarden copié depuis Cmd+T).
    func record(_ item: ClipboardItem) {
        let kept = history.add(item)
        store?.save(kept)
        onChange?()
    }

    /// Vide le presse-papier après un délai, s'il contient toujours ce que l'app y a mis.
    func clearLater(after delay: Duration) {
        let count = NSPasteboard.general.changeCount
        Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard NSPasteboard.general.changeCount == count else { return }
            NSPasteboard.general.clearContents()
            self?.markOwn()
        }
    }

    private func markOwn() {
        let count = NSPasteboard.general.changeCount
        ownChangeCounts.insert(count)
        lastChangeCount = count
    }

    /// Touch ID (ou mot de passe du Mac) avant d'afficher ou recoller un secret.
    static func authenticate(reason: String) async -> Bool {
        let context = LAContext()
        context.localizedFallbackTitle = "Utiliser le mot de passe"
        do { return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) }
        catch { return false }
    }

    private static func appName(_ bundleID: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
}

/// Signale les copies faites dans une page (`copy`, `cut`), depuis un monde isolé invisible pour la page.
@MainActor
final class CopyRelay: NSObject, WKScriptMessageHandler {
    static let shared = CopyRelay()
    private static let name = "visionCopy"
    /// Reçoit la vue web où la copie a eu lieu, et si elle vient d'un cadre de l'extension (menu Bitwarden).
    var onCopy: ((WKWebView?, Bool) -> Void)?

    static let source = """
    (() => {
      const notify = () => window.webkit.messageHandlers.\(name).postMessage(null);
      document.addEventListener('copy', notify, true);
      document.addEventListener('cut', notify, true);
    })();
    """

    static func install(on config: WKWebViewConfiguration) {
        let controller = config.userContentController
        controller.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: ScriptWorld.app))
        controller.add(shared, contentWorld: ScriptWorld.app, name: name)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        let fromExtension = message.frameInfo.securityOrigin.protocol.hasSuffix("-extension")
        onCopy?(message.webView, fromExtension)
    }
}
