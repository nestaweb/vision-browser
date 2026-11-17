import Foundation

/// Règles de l'indicateur de domaine (fonctionnalité F1) : quand l'afficher, et quand alerter.
enum DomainPolicy {
    /// Hôte affiché à l'utilisateur, sans « www. ».
    static func displayHost(for url: URL?) -> String? {
        guard let host = url?.host(percentEncoded: false)?.lowercased(), !host.isEmpty else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// On annonce le domaine quand on arrive sur un hôte différent du précédent.
    static func shouldAnnounce(previous: URL?, next: URL?) -> Bool {
        guard let nextHost = displayHost(for: next) else { return false }
        return displayHost(for: previous) != nextHost
    }

    /// Page non chiffrée vers un hôte public : liseré d'alerte.
    /// Le développement local (localhost, *.test, IP privées) n'est pas signalé.
    static func isInsecure(_ url: URL?) -> Bool {
        guard let url, url.scheme?.lowercased() == "http", let host = displayHost(for: url) else { return false }
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".test") || host.hasSuffix(".local") { return false }
        let octets = host.split(separator: ".").compactMap { Int($0) }
        if octets.count == 4 {
            switch (octets[0], octets[1]) {
            case (10, _), (127, _), (192, 168): return false
            case (172, 16...31): return false
            default: return true
            }
        }
        return true
    }
}
