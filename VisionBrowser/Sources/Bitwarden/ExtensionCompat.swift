import WebKit

/// Couche de compatibilité WebKit pour les pages des extensions (arrière-plan, popup).
/// Contrairement au relais de console (diagnostic), ceci fait partie du navigateur.
@MainActor
enum ExtensionCompat {
    /// Permissions que WebKit ne connaît pas. Chrome et Firefox répondent « non accordée »
    /// quand on les interroge ; WebKit lève une exception (« not a valid permission »).
    /// Bitwarden demande `privacy` en activant les suggestions dans les champs, pour proposer
    /// de désactiver le gestionnaire de mots de passe du navigateur ; l'exception interrompait
    /// l'enregistrement du réglage. On répond donc « non accordée », comme un navigateur qui refuse.
    static let unsupportedPermissions = ["privacy"]

    static var source: String {
        let list = unsupportedPermissions.map { "'\($0)'" }.joined(separator: ", ")
        return """
        (() => {
          const UNSUPPORTED = new Set([\(list)]);
          const page = location.pathname.split('/').pop();
          let patched = 0;
          // WebKit recrée l'objet `chrome.permissions` après le chargement : on modifie donc
          // son prototype (partagé par les objets recréés), pas l'objet lui-même.
          // `contains`/`request` y sont en lecture seule : une affectation simple échouerait
          // en silence, d'où defineProperty (les propriétés restent « configurable »).
          const ns = globalThis.browser || globalThis.chrome;
          const proto = ns && ns.permissions && Object.getPrototypeOf(ns.permissions);
          if (proto && !Object.prototype.hasOwnProperty.call(proto, '__visionCompat')) {
            Object.defineProperty(proto, '__visionCompat', { value: true });
            for (const name of ['contains', 'request']) {
              const original = proto[name];
              if (typeof original !== 'function') continue;
              Object.defineProperty(proto, name, { configurable: true, writable: true, value: function (...args) {
                const asked = (args[0] && args[0].permissions) || [];
                const unsupported = asked.filter(x => UNSUPPORTED.has(x));
                if (!unsupported.length) return original.apply(this, args);
                console.info('[Vision compat] permissions.' + name + '(' + unsupported.join(', ') + ') : non prise en charge par WebKit, réponse « non accordée »');
                const callback = args.find(a => typeof a === 'function');
                if (callback) { setTimeout(() => callback(false), 0); return; }
                return Promise.resolve(false);
              } });
              patched++;
            }
          }
          console.info('[Vision compat] ' + page + ' : ' + patched + ' fonction(s) de permissions adaptée(s)');
        })();
        """
    }

    static func install(on configuration: WKWebViewConfiguration) {
        configuration.userContentController.addUserScript(
            WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false))
    }
}
