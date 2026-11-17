import WebKit

/// Console de diagnostic des pages d'extension, désactivée par défaut.
/// Activation : lancer l'app avec `--debug-extensions`. Le journal est écrit dans
/// ~/Library/Application Support/Vision Browser/extension-console.log
/// (n'y figurent que des noms de commandes et des adresses de pages, jamais de mots de passe ;
///  les messages d'état internes de Bitwarden sont ignorés).
@MainActor
final class ExtensionDebugConsole: NSObject, WKScriptMessageHandler {
    static let isEnabled = CommandLine.arguments.contains("--debug-extensions")
    private static let shared = ExtensionDebugConsole()
    private var handle: FileHandle?

    static func installIfEnabled(on configuration: WKWebViewConfiguration) {
        guard isEnabled else { return }
        shared.openLogIfNeeded()
        configuration.userContentController.addUserScript(
            WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        configuration.userContentController.add(shared, name: "visionDebugConsole")
    }

    private func openLogIfNeeded() {
        guard handle == nil else { return }
        let url = AppPaths.applicationSupport.appendingPathComponent("extension-console.log")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try? FileHandle(forWritingTo: url)
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        let stamp = Date().formatted(.dateTime.hour().minute().second())
        handle?.write(Data("[\(stamp)] \(String(describing: message.body))\n".utf8))
    }

    private static let source = """
    (() => {
      if (!/^webkit-extension:$/.test(location.protocol) || window.__visionDebugConsole) return;
      window.__visionDebugConsole = true;
      const where = location.pathname.split('/').pop() || location.host;
      const send = (level, args) => { try { window.webkit.messageHandlers.visionDebugConsole.postMessage(level + ' [' + where + '] ' + Array.from(args).map(a => {
        if (a instanceof Error) return a.name + ': ' + a.message;
        if (typeof a === 'string') return a;
        try { return JSON.stringify(a); } catch (e) { return String(a); } }).join(' ').slice(0, 500)); } catch (e) {} };
      for (const level of ['warn', 'error', 'info']) {
        const original = console[level];
        console[level] = function () { send(level.toUpperCase(), arguments); return original.apply(this, arguments); };
      }
      window.addEventListener('error', e => send('ONERROR', [e.message + ' (' + e.filename + ':' + e.lineno + ')']));
      window.addEventListener('unhandledrejection', e => send('REJECTION', [e.reason]));
    })();
    """
}
