import AppKit

@main
enum VisionBrowserMain {
    static func main() {
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            let delegate = AppDelegate()
            app.delegate = delegate
            app.setActivationPolicy(.regular)
            app.run()
            _ = delegate // garde le délégué en vie pendant toute la boucle de l'app
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let host = ExtensionHost()
    private var browser: BrowserWindowController?
    /// Liens reçus (autres apps, navigateur par défaut) avant que la fenêtre soit prête.
    private var pendingURLs: [URL] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Lancée par les tests unitaires : ni fenêtre, ni Bitwarden, ni session
        // (sinon les tests liraient et réécriraient les vrais onglets de l'utilisateur).
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return }
        NSApp.mainMenu = MainMenu.build()
        ClipboardMonitor.shared.start()
        Task { await BitwardenService.shared.refreshStatus() }
        Task {
            // L'extension est chargée AVANT les onglets : elle doit les connaître dès leur premier chargement.
            let report = await host.loadBitwarden()
            report.forEach { NSLog("Vision Browser · Bitwarden : \($0)") }
            MainMenu.installBitwardenMenu(host: host)

            let controller = BrowserWindowController(host: host, session: .default, spacesStore: .default)
            controller.onSpacesChanged = { [weak controller] in
                if let controller { MainMenu.updateSpacesMenu(for: controller) }
            }
            browser = controller
            controller.showWindow(nil)
            controller.restoreSession(extraURLs: pendingURLs)
            pendingURLs.removeAll()
            NSApp.activate()
        }
    }

    /// Liens ouverts depuis une autre app (Vision Browser comme navigateur par défaut) :
    /// une règle de routage choisit l'espace (ex. crm.zoho.eu → « Pro B »), sinon l'espace affiché.
    func application(_ application: NSApplication, open urls: [URL]) {
        let web = urls.filter { ["http", "https", "file"].contains($0.scheme?.lowercased() ?? "") }
        if let browser { web.forEach(browser.openExternal) }
        else { pendingURLs.append(contentsOf: web) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        browser?.saveSessionNow()
        BitwardenService.shared.lockBeforeQuit()
    }
}
