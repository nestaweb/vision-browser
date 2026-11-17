import AppKit

/// Vue qui laisse passer les clics vers la page en dessous.
class PassthroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Bande invisible en haut de la fenêtre qui permet de la déplacer (il n'y a pas de barre de titre).
final class WindowDragStrip: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
}

/// Zone du coin supérieur gauche : signale le survol pour afficher les boutons de la fenêtre.
final class TrafficLightZone: NSView {
    var onHover: ((Bool) -> Void)?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        // .inVisibleRect : la zone suit la taille réelle de la vue, même après la mise en page.
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
    // Les clics passent aux boutons de la fenêtre (dessinés dans la barre de titre transparente).
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Indicateur de domaine (F1) : une pastille discrète qui apparaît 1,5 s puis s'efface.
@MainActor
final class DomainToastView: NSVisualEffectView {
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let spaceDot = NSView()
    private let spaceLabel = NSTextField(labelWithString: "")
    private var hideTask: Task<Void, Never>?

    init() {
        super.init(frame: .zero)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 13
        alphaValue = 0
        label.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        label.textColor = .labelColor
        icon.symbolConfiguration = .init(pointSize: 11, weight: .semibold)
        spaceDot.wantsLayer = true
        spaceDot.layer?.cornerRadius = 4
        spaceDot.translatesAutoresizingMaskIntoConstraints = false
        spaceDot.widthAnchor.constraint(equalToConstant: 8).isActive = true
        spaceDot.heightAnchor.constraint(equalToConstant: 8).isActive = true
        spaceLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        spaceLabel.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [icon, label, spaceDot, spaceLabel])
        stack.setCustomSpacing(12, after: label)
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 5, left: 10, bottom: 5, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("non utilisé") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// - Parameter space: nom et couleur de l'espace à rappeler (deux comptes Zoho se ressemblent).
    func show(text: String, symbol: String, tint: NSColor, space: (name: String, color: NSColor)? = nil) {
        label.stringValue = text
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.contentTintColor = tint
        spaceDot.isHidden = space == nil
        spaceLabel.isHidden = space == nil
        spaceDot.layer?.backgroundColor = space?.color.cgColor
        spaceLabel.stringValue = space?.name ?? ""
        let view = self
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            MainActor.assumeIsolated { view.animator().alphaValue = 1 }
        }
        hideTask?.cancel()
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(1500))
            guard !Task.isCancelled, let self else { return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.4
                MainActor.assumeIsolated { self.animator().alphaValue = 0 }
            }, completionHandler: nil)
        }
    }
}
