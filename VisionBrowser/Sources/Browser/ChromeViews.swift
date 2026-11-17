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
        let stack = NSStackView(views: [icon, label])
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

    func show(text: String, secure: Bool, detail: String?) {
        label.stringValue = text
        icon.image = NSImage(systemSymbolName: secure ? "lock.fill" : "exclamationmark.triangle.fill", accessibilityDescription: nil)
        icon.contentTintColor = secure ? .systemGreen : .systemRed
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

/// Barre d'adresse en surcouche (version simple de la phase 1 ; la barre complète arrive en phase 2).
@MainActor
final class AddressBarView: NSVisualEffectView, NSTextFieldDelegate {
    let field = NSTextField()
    private let hint = NSTextField(labelWithString: "")
    var onSubmit: ((String, Bool) -> Void)?
    var onCancel: (() -> Void)?
    private var isNewTab = false

    init() {
        super.init(frame: .zero)
        material = .popover
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        shadow = NSShadow()
        layer?.shadowOpacity = 0.25
        layer?.shadowRadius = 24

        field.font = .systemFont(ofSize: 20)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.placeholderString = "Rechercher ou saisir une adresse"
        field.delegate = self
        field.cell?.usesSingleLineMode = true
        field.cell?.isScrollable = true
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [field, hint])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 18, bottom: 12, right: 18)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            field.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -36),
        ])
    }

    required init?(coder: NSCoder) { fatalError("non utilisé") }

    func present(text: String, newTab: Bool) {
        isNewTab = newTab
        field.stringValue = text
        hint.stringValue = newTab ? "Entrée : ouvrir dans un nouvel onglet · Échap : annuler"
                                  : "Entrée : ouvrir dans cet onglet · Échap : annuler"
        isHidden = false
        field.selectText(nil)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            onSubmit?(field.stringValue, isNewTab); return true
        case #selector(NSResponder.cancelOperation(_:)):
            onCancel?(); return true
        default:
            return false
        }
    }
}
