import Foundation

/// Les quatre statuts d'une tâche (fixes, dans l'ordre où on les traite).
enum TaskStatus: String, Codable, CaseIterable, Sendable {
    case doing, todo, waiting, done
}

/// Une tâche de la page d'accueil, telle qu'elle part vers la page (JSON).
///
/// Projet et sous-projet sont de simples noms (un niveau de sous-projet) : renommer un projet revient à changer
/// le nom sur ses tâches. L'espace est celui où la tâche a été créée ; la couleur d'un projet vient de là.
/// L'échéance est un jour (`2026-11-20`), sans heure ni fuseau.
struct TaskItem: Codable, Equatable, Sendable {
    struct Link: Codable, Equatable, Sendable {
        var id: Int64
        var url: String
        var title: String
    }
    struct Subtask: Codable, Equatable, Sendable {
        var id: Int64
        var title: String
        var done: Bool
    }

    var id: Int64
    var title: String
    var status: TaskStatus
    var project: String
    var sub: String
    var spaceID: String?
    var due: String?
    var notes: String
    var links: [Link] = []
    var subtasks: [Subtask] = []
    var created: Double
    var updated: Double
}

/// Les tâches, dans une base SQLite locale (même outil que l'historique : rien ne quitte le Mac).
@MainActor
final class TaskStore {
    private let db: Database
    private let now: () -> Date

    static func openDefault() -> TaskStore? {
        try? FileManager.default.createDirectory(at: AppPaths.applicationSupport, withIntermediateDirectories: true)
        return try? TaskStore(path: AppPaths.applicationSupport.appendingPathComponent("tasks.sqlite").path)
    }

    init(path: String, now: @escaping () -> Date = Date.init) throws {
        db = try Database(path: path)
        self.now = now
        try db.execute("""
        CREATE TABLE IF NOT EXISTS tasks (
            id INTEGER PRIMARY KEY,
            title TEXT NOT NULL,
            status TEXT NOT NULL DEFAULT 'todo',
            project TEXT NOT NULL DEFAULT '',
            sub TEXT NOT NULL DEFAULT '',
            space_id TEXT,
            due TEXT,
            notes TEXT NOT NULL DEFAULT '',
            created REAL NOT NULL,
            updated REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS task_links (
            id INTEGER PRIMARY KEY,
            task_id INTEGER NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
            url TEXT NOT NULL,
            title TEXT NOT NULL DEFAULT '',
            position INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE IF NOT EXISTS subtasks (
            id INTEGER PRIMARY KEY,
            task_id INTEGER NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
            title TEXT NOT NULL,
            done INTEGER NOT NULL DEFAULT 0,
            position INTEGER NOT NULL DEFAULT 0
        );
        CREATE INDEX IF NOT EXISTS task_links_task ON task_links(task_id);
        CREATE INDEX IF NOT EXISTS subtasks_task ON subtasks(task_id);
        """)
    }

    // MARK: Lecture

    func all() -> [TaskItem] {
        var items: [TaskItem] = []
        try? db.run("SELECT id, title, status, project, sub, space_id, due, notes, created, updated FROM tasks ORDER BY id") { row in
            items.append(TaskItem(id: row.integer(0), title: row.text(1) ?? "", status: TaskStatus(rawValue: row.text(2) ?? "") ?? .todo,
                                  project: row.text(3) ?? "", sub: row.text(4) ?? "", spaceID: row.text(5), due: row.text(6),
                                  notes: row.text(7) ?? "", created: row.double(8), updated: row.double(9)))
        }
        var links: [Int64: [TaskItem.Link]] = [:], subtasks: [Int64: [TaskItem.Subtask]] = [:]
        try? db.run("SELECT id, task_id, url, title FROM task_links ORDER BY position, id") { row in
            links[row.integer(1), default: []].append(.init(id: row.integer(0), url: row.text(2) ?? "", title: row.text(3) ?? ""))
        }
        try? db.run("SELECT id, task_id, title, done FROM subtasks ORDER BY position, id") { row in
            subtasks[row.integer(1), default: []].append(.init(id: row.integer(0), title: row.text(2) ?? "", done: row.integer(3) != 0))
        }
        return items.map { item in
            var item = item
            item.links = links[item.id] ?? []
            item.subtasks = subtasks[item.id] ?? []
            return item
        }
    }

    func task(_ id: Int64) -> TaskItem? { all().first { $0.id == id } }

    // MARK: Écriture

    @discardableResult
    func add(title: String, project: String = "", sub: String = "", spaceID: String?, due: String? = nil) -> TaskItem? {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        let date = now().timeIntervalSince1970
        try? db.run("INSERT INTO tasks (title, project, sub, space_id, due, created, updated) VALUES (?, ?, ?, ?, ?, ?, ?)",
                    [.text(title), .text(project), .text(sub), Self.optional(spaceID), Self.optional(due), .double(date), .double(date)])
        var id: Int64 = 0
        try? db.run("SELECT last_insert_rowid()") { id = $0.integer(0) }
        return task(id)
    }

    /// Champs modifiables d'une tâche ; `nil` laisse le champ tel quel (pour l'échéance : `.some(nil)` l'efface).
    struct Changes: Decodable, Sendable {
        var title: String?
        var status: TaskStatus?
        var project: String?
        var sub: String?
        var due: String??
        var notes: String?

        init(title: String? = nil, status: TaskStatus? = nil, project: String? = nil, sub: String? = nil, due: String?? = nil, notes: String? = nil) {
            (self.title, self.status, self.project, self.sub, self.due, self.notes) = (title, status, project, sub, due, notes)
        }

        // Une clé « due » présente mais nulle efface l'échéance ; absente, elle la laisse.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Key.self)
            title = try c.decodeIfPresent(String.self, forKey: .title)
            status = try c.decodeIfPresent(TaskStatus.self, forKey: .status)
            project = try c.decodeIfPresent(String.self, forKey: .project)
            sub = try c.decodeIfPresent(String.self, forKey: .sub)
            notes = try c.decodeIfPresent(String.self, forKey: .notes)
            due = c.contains(.due) ? .some(try c.decodeIfPresent(String.self, forKey: .due)) : nil
        }
        private enum Key: String, CodingKey { case title, status, project, sub, due, notes }
    }

    func update(_ id: Int64, _ changes: Changes) {
        var sets: [String] = [], values: [Database.Value] = []
        if let title = changes.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty { sets.append("title = ?"); values.append(.text(title)) }
        if let status = changes.status { sets.append("status = ?"); values.append(.text(status.rawValue)) }
        if let project = changes.project { sets.append("project = ?"); values.append(.text(project.trimmingCharacters(in: .whitespaces))) }
        if let sub = changes.sub { sets.append("sub = ?"); values.append(.text(sub.trimmingCharacters(in: .whitespaces))) }
        if let due = changes.due { sets.append("due = ?"); values.append(Self.optional(due)) }
        if let notes = changes.notes { sets.append("notes = ?"); values.append(.text(notes)) }
        guard !sets.isEmpty else { return }
        sets.append("updated = ?")
        values += [.double(now().timeIntervalSince1970), .integer(id)]
        try? db.run("UPDATE tasks SET \(sets.joined(separator: ", ")) WHERE id = ?", values)
    }

    func delete(_ id: Int64) {
        try? db.run("DELETE FROM tasks WHERE id = ?", [.integer(id)])
    }

    func addSubtask(to taskID: Int64, title: String) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        try? db.run("INSERT INTO subtasks (task_id, title, position) VALUES (?, ?, (SELECT COUNT(*) FROM subtasks WHERE task_id = ?))",
                    [.integer(taskID), .text(title), .integer(taskID)])
        touch(taskID)
    }

    func setSubtask(_ id: Int64, done: Bool) {
        try? db.run("UPDATE subtasks SET done = ? WHERE id = ?", [.integer(done ? 1 : 0), .integer(id)])
    }

    func deleteSubtask(_ id: Int64) {
        try? db.run("DELETE FROM subtasks WHERE id = ?", [.integer(id)])
    }

    /// Lie une page à la tâche (une même adresse n'est liée qu'une fois).
    func addLink(to taskID: Int64, url: URL, title: String) {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else { return }
        var exists = false
        try? db.run("SELECT 1 FROM task_links WHERE task_id = ? AND url = ?", [.integer(taskID), .text(url.absoluteString)]) { _ in exists = true }
        guard !exists else { return }
        try? db.run("INSERT INTO task_links (task_id, url, title, position) VALUES (?, ?, ?, (SELECT COUNT(*) FROM task_links WHERE task_id = ?))",
                    [.integer(taskID), .text(url.absoluteString), .text(title), .integer(taskID)])
        touch(taskID)
    }

    func deleteLink(_ id: Int64) {
        try? db.run("DELETE FROM task_links WHERE id = ?", [.integer(id)])
    }

    private func touch(_ id: Int64) {
        try? db.run("UPDATE tasks SET updated = ? WHERE id = ?", [.double(now().timeIntervalSince1970), .integer(id)])
    }

    private static func optional(_ text: String?) -> Database.Value { text.map { .text($0) } ?? .null }
}

/// Saisie rapide d'une tâche : « Relancer le devis #Clients/Studio Mer !ven ».
///
/// `#projet/sous-projet` (jusqu'au `!` suivant ou à la fin) ; `!auj`, `!demain`, `!lun`… `!dim` (le prochain, jamais
/// aujourd'hui), `!24/11` (cette année, ou la suivante si la date est passée), `!3j` (dans 3 jours).
struct QuickTask: Equatable, Sendable {
    var title: String
    var project: String?
    var sub: String?
    var due: String?

    static func parse(_ text: String, today: Date, calendar: Calendar = .current) -> QuickTask {
        var rest = text, project: String?, sub: String?, due: String?

        if let range = rest.range(of: #"#([^!#]+)"#, options: .regularExpression) {
            let parts = rest[range].dropFirst().split(separator: "/", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            project = parts.first.flatMap { $0.isEmpty ? nil : $0 }
            sub = parts.count > 1 && !parts[1].isEmpty ? parts[1] : nil
            rest.removeSubrange(range)
        }
        if let range = rest.range(of: #"!(\S+)"#, options: .regularExpression),
           let date = date(from: String(rest[range].dropFirst()), today: today, calendar: calendar) {
            due = dayString(date, calendar: calendar)
            rest.removeSubrange(range)
        }
        let title = rest.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return QuickTask(title: title, project: project, sub: sub, due: due)
    }

    static func date(from word: String, today: Date, calendar: Calendar) -> Date? {
        let word = word.lowercased().folding(options: .diacriticInsensitive, locale: Locale(identifier: "fr_FR"))
        let start = calendar.startOfDay(for: today)
        let add = { (days: Int) in calendar.date(byAdding: .day, value: days, to: start) }
        switch word {
        case "auj", "aujourd'hui", "aujourdhui": return start
        case "demain": return add(1)
        case "apres-demain": return add(2)
        default: break
        }
        // Jours de la semaine (calendrier grégorien : dimanche = 1).
        let weekdays = ["dim": 1, "lun": 2, "mar": 3, "mer": 4, "jeu": 5, "ven": 6, "sam": 7]
        if word.count >= 3, let target = weekdays[String(word.prefix(3))] {
            let current = calendar.component(.weekday, from: start)
            let gap = (target - current + 7) % 7
            return add(gap == 0 ? 7 : gap)
        }
        if let match = word.wholeMatch(of: /(\d{1,3})j/), let days = Int(match.1) { return add(days) }
        if let match = word.wholeMatch(of: /(\d{1,2})\/(\d{1,2})/), let dayNumber = Int(match.1), let month = Int(match.2) {
            let year = calendar.component(.year, from: start)
            guard let date = calendar.date(from: DateComponents(year: year, month: month, day: dayNumber)),
                  calendar.component(.day, from: date) == dayNumber else { return nil }
            return date < start ? calendar.date(byAdding: .year, value: 1, to: date) : date
        }
        return nil
    }

    static func dayString(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}
