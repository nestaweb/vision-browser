import AppKit

/// Captures des onglets (cartes de l'étagère, de la vue d'ensemble et du sélecteur Ctrl+Tab).
/// Gardées en mémoire et sur disque (JPEG réduit) pour survivre à la mise en veille et à une relance.
@MainActor
final class SnapshotStore {
    static let shared = SnapshotStore(directory: AppPaths.applicationSupport.appendingPathComponent("Snapshots", isDirectory: true))

    private let directory: URL
    private var cache: [UUID: NSImage] = [:]
    /// Captures absentes du disque, pour ne pas relire le disque à chaque affichage.
    private var missing: Set<UUID> = []

    init(directory: URL) { self.directory = directory }

    func image(for id: UUID) -> NSImage? {
        if let image = cache[id] { return image }
        guard !missing.contains(id) else { return nil }
        if let image = NSImage(contentsOf: fileURL(id)) {
            cache[id] = image
            return image
        }
        missing.insert(id)
        return nil
    }

    func store(_ image: NSImage, for id: UUID) {
        cache[id] = image
        missing.remove(id)
        guard let tiff = image.tiffRepresentation else { return }
        let url = fileURL(id), folder = directory
        // Compression et écriture hors du fil principal : la bascule d'onglet ne doit jamais attendre le disque.
        Task.detached(priority: .utility) {
            guard let jpeg = NSBitmapImageRep(data: tiff)?.representation(using: .jpeg, properties: [.compressionFactor: 0.7]) else { return }
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? jpeg.write(to: url, options: .atomic)
        }
    }

    /// Oublie la capture d'un onglet dont la page a changé sans être affichée (elle montrerait l'ancienne page).
    func forget(_ id: UUID) {
        cache[id] = nil
        missing.insert(id)
        let url = fileURL(id)
        Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: url) }
    }

    /// Supprime les captures des onglets qui n'existent plus (ni ouverts, ni archivés).
    func prune(keeping ids: Set<UUID>) {
        cache = cache.filter { ids.contains($0.key) }
        let folder = directory
        Task.detached(priority: .background) {
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            for file in files where file.pathExtension == "jpg" {
                if let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent), !ids.contains(id) {
                    try? FileManager.default.removeItem(at: file)
                }
            }
        }
    }

    private func fileURL(_ id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString).jpg") }
}
