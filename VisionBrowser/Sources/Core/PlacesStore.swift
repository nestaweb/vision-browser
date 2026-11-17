import Foundation

/// Une adresse connue : visitée (historique) et/ou mise en favori.
struct Place: Equatable, Sendable {
    var url: URL
    var title: String?
    var visitCount: Int
    var lastVisit: Date
    var isFavorite: Bool
    /// Pertinence calculée pour une recherche (plus grand = meilleur).
    var score: Double = 0
}

/// Historique et favoris, avec recherche plein texte (FTS5) et classement par pertinence.
@MainActor
final class PlacesStore {
    private let db: Database

    static func openDefault() -> PlacesStore? {
        try? FileManager.default.createDirectory(at: AppPaths.applicationSupport, withIntermediateDirectories: true)
        return try? PlacesStore(path: AppPaths.applicationSupport.appendingPathComponent("places.sqlite").path)
    }

    init(path: String) throws {
        db = try Database(path: path)
        try db.execute("""
        CREATE TABLE IF NOT EXISTS places (
            id INTEGER PRIMARY KEY,
            url TEXT NOT NULL UNIQUE,
            title TEXT,
            host TEXT NOT NULL DEFAULT '',
            visit_count INTEGER NOT NULL DEFAULT 0,
            last_visit REAL NOT NULL DEFAULT 0,
            is_favorite INTEGER NOT NULL DEFAULT 0
        );
        CREATE INDEX IF NOT EXISTS places_host ON places(host);
        CREATE VIRTUAL TABLE IF NOT EXISTS places_fts USING fts5(
            title, url, content='places', content_rowid='id', tokenize='unicode61 remove_diacritics 2'
        );
        CREATE TRIGGER IF NOT EXISTS places_ai AFTER INSERT ON places BEGIN
            INSERT INTO places_fts(rowid, title, url) VALUES (new.id, new.title, new.url);
        END;
        CREATE TRIGGER IF NOT EXISTS places_ad AFTER DELETE ON places BEGIN
            INSERT INTO places_fts(places_fts, rowid, title, url) VALUES ('delete', old.id, old.title, old.url);
        END;
        CREATE TRIGGER IF NOT EXISTS places_au AFTER UPDATE OF title, url ON places BEGIN
            INSERT INTO places_fts(places_fts, rowid, title, url) VALUES ('delete', old.id, old.title, old.url);
            INSERT INTO places_fts(rowid, title, url) VALUES (new.id, new.title, new.url);
        END;
        """)
    }

    // MARK: Écriture

    /// Enregistre une visite. Seules les pages web (http/https) entrent dans l'historique.
    func recordVisit(url: URL, title: String?, at date: Date = Date()) {
        guard Self.isRecordable(url) else { return }
        let titleValue: Database.Value = title.map { .text($0) } ?? .null
        let values: [Database.Value] = [.text(Self.key(url)), titleValue, .text(Self.host(url)), .double(date.timeIntervalSince1970)]
        try? db.run("""
        INSERT INTO places(url, title, host, visit_count, last_visit) VALUES (?, ?, ?, 1, ?)
        ON CONFLICT(url) DO UPDATE SET visit_count = visit_count + 1, last_visit = excluded.last_visit,
            title = COALESCE(excluded.title, places.title)
        """, values)
    }

    /// Met à jour le titre (il arrive souvent après l'adresse).
    func updateTitle(url: URL, title: String) {
        guard Self.isRecordable(url), !title.isEmpty else { return }
        let values: [Database.Value] = [.text(title), .text(Self.key(url)), .text(title)]
        try? db.run("UPDATE places SET title = ? WHERE url = ? AND (title IS NULL OR title != ?)", values)
    }

    /// Ajoute ou retire un favori ; renvoie le nouvel état.
    @discardableResult
    func toggleFavorite(url: URL, title: String?) -> Bool {
        guard Self.isRecordable(url) else { return false }
        let now: Int64 = isFavorite(url) ? 0 : 1
        let titleValue: Database.Value = title.map { .text($0) } ?? .null
        let values: [Database.Value] = [.text(Self.key(url)), titleValue, .text(Self.host(url)), .integer(now)]
        try? db.run("""
        INSERT INTO places(url, title, host, is_favorite) VALUES (?, ?, ?, ?)
        ON CONFLICT(url) DO UPDATE SET is_favorite = excluded.is_favorite, title = COALESCE(places.title, excluded.title)
        """, values)
        return now == 1
    }

    func isFavorite(_ url: URL) -> Bool {
        var result = false
        try? db.run("SELECT is_favorite FROM places WHERE url = ?", [.text(Self.key(url))]) { result = $0.integer(0) == 1 }
        return result
    }

    // MARK: Lecture

    func favorites(limit: Int = 20) -> [Place] {
        var places: [Place] = []
        try? db.run("SELECT url, title, visit_count, last_visit, is_favorite FROM places WHERE is_favorite = 1 ORDER BY last_visit DESC LIMIT ?",
                    [.integer(Int64(limit))]) { places.append(Self.place(from: $0)) }
        return places
    }

    /// Recherche plein texte classée : pertinence du texte + fréquence/fraîcheur + bonus de domaine.
    func search(_ query: String, limit: Int = 8, now: Date = Date()) -> [Place] {
        let tokens = Self.tokens(query)
        guard !tokens.isEmpty else { return [] }
        let match = tokens.map { "\"\($0)\"*" }.joined(separator: " ")
        var places: [Place] = []
        try? db.run("""
        SELECT p.url, p.title, p.visit_count, p.last_visit, p.is_favorite, bm25(places_fts, 3.0, 1.0), p.host
        FROM places_fts JOIN places p ON p.id = places_fts.rowid
        WHERE places_fts MATCH ? ORDER BY bm25(places_fts, 3.0, 1.0) LIMIT 60
        """, [.text(match)]) { row in
            var place = Self.place(from: row)
            place.score = Self.score(textRank: row.double(5), host: row.text(6) ?? "", place: place, tokens: tokens, now: now)
            places.append(place)
        }
        return Array(places.sorted { $0.score > $1.score }.prefix(limit))
    }

    // MARK: Règles

    static func isRecordable(_ url: URL) -> Bool { ["http", "https"].contains(url.scheme?.lowercased() ?? "") }

    /// Adresse normalisée (sans fragment #…) pour qu'une même page n'apparaisse qu'une fois.
    static func key(_ url: URL) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.fragment = nil
        return components?.url?.absoluteString ?? url.absoluteString
    }

    static func host(_ url: URL) -> String { DomainPolicy.displayHost(for: url) ?? "" }

    static func tokens(_ query: String) -> [String] {
        query.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    /// bm25 est négatif (plus il est bas, meilleur c'est) ; on l'inverse et on ajoute l'usage.
    static func score(textRank: Double, host: String, place: Place, tokens: [String], now: Date) -> Double {
        let text = -textRank * 10
        let frequency = log2(Double(place.visitCount) + 1) * 4
        let days = max(0, now.timeIntervalSince(place.lastVisit) / 86_400)
        let freshness = 12 * exp(-days / 14)
        let hostBonus = tokens.first.map { first in host.hasPrefix(first) || host.contains(".\(first)") ? 40.0 : 0 } ?? 0
        let favoriteBonus = place.isFavorite ? 8.0 : 0
        return text + frequency + freshness + hostBonus + favoriteBonus
    }

    private static func place(from row: Database.Row) -> Place {
        Place(url: URL(string: row.text(0) ?? "") ?? URL(string: "about:blank")!,
              title: row.text(1), visitCount: Int(row.integer(2)),
              lastVisit: Date(timeIntervalSince1970: row.double(3)), isFavorite: row.integer(4) == 1)
    }
}
