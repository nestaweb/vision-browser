import Foundation
import SQLite3

/// Petite enveloppe autour de SQLite système (FTS5 inclus dans macOS) : pas de dépendance externe.
/// Utilisée uniquement depuis le fil principal : les requêtes locales prennent moins d'une milliseconde.
@MainActor
final class Database {
    enum DBError: Error, CustomStringConvertible {
        case sqlite(String)
        var description: String { if case .sqlite(let message) = self { return message }; return "" }
    }

    /// Utilisée seulement sur le fil principal ; fermée une seule fois dans deinit.
    nonisolated(unsafe) private var handle: OpaquePointer?

    /// - Parameter path: chemin du fichier, ou `":memory:"` (tests).
    init(path: String) throws {
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            throw DBError.sqlite(String(cString: sqlite3_errmsg(handle)))
        }
        try execute("PRAGMA journal_mode = WAL")
        try execute("PRAGMA foreign_keys = ON")
    }

    deinit { sqlite3_close(handle) }

    func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "erreur inconnue"
            sqlite3_free(error)
            throw DBError.sqlite(message)
        }
    }

    /// Exécute une requête paramétrée ; `row` est appelé pour chaque ligne de résultat.
    func run(_ sql: String, _ bindings: [Value] = [], row: ((Row) -> Void)? = nil) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DBError.sqlite(String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(statement) }
        for (index, value) in bindings.enumerated() {
            let position = Int32(index + 1)
            switch value {
            case .text(let text): sqlite3_bind_text(statement, position, text, -1, Self.transient)
            case .integer(let int): sqlite3_bind_int64(statement, position, int)
            case .double(let double): sqlite3_bind_double(statement, position, double)
            case .null: sqlite3_bind_null(statement, position)
            }
        }
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_ROW { row?(Row(statement: statement)) }
            else if status == SQLITE_DONE { break }
            else { throw DBError.sqlite(String(cString: sqlite3_errmsg(handle))) }
        }
    }

    var changes: Int { Int(sqlite3_changes(handle)) }

    enum Value {
        case text(String), integer(Int64), double(Double), null
    }

    struct Row {
        let statement: OpaquePointer?
        func text(_ column: Int32) -> String? {
            sqlite3_column_text(statement, column).map { String(cString: $0) }
        }
        func integer(_ column: Int32) -> Int64 { sqlite3_column_int64(statement, column) }
        func double(_ column: Int32) -> Double { sqlite3_column_double(statement, column) }
    }

    /// SQLite copie le texte lié (la chaîne Swift peut disparaître avant l'exécution).
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}
