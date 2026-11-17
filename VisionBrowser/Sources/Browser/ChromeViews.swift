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

/// Étiquette du haut (F1, direction « Scène ») : l'espace et le site, annoncés brièvement à chaque changement,
/// et les messages courts (« Rempli », « Copié »…).
///
/// Sobre : une petite capsule claire, un trait de la couleur de l'espace, le texte. Le symbole est monochrome ;
/// seuls les avertissements (rouge, orange : site non sécurisé, échec) gardent une couleur, la brique sourde.
/// Elle descend du haut et y remonte ; si un nouveau message arrive pendant qu'elle est affichée, seul le texte change.
@MainActor
final class DomainToastView: NSView {
    private let spaceMark = NSView()
    private let spaceLabel = NSTextField(labelWithString: "")
    private let separator = NSView()
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private var stack: NSStackView!
    private var hideTask: Task<Void, Never>?
    private var isShown = false

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Design.Palette.sheet.withAlphaComponent(0.94).cgColor
        layer?.cornerRadius = 14
        layer?.borderWidth = 0.5
        layer?.borderColor = Design.Palette.ink.withAlphaComponent(0.14).cgColor
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.10
        layer?.shadowRadius = 8
        layer?.shadowOffset = CGSize(width: 0, height: -3)
        alphaValue = 0
        isHidden = true

        spaceMark.wantsLayer = true
        spaceMark.layer?.cornerRadius = 1.5
        spaceMark.translatesAutoresizingMaskIntoConstraints = false
        spaceLabel.font = .systemFont(ofSize: Design.Typography.smallSize, weight: .semibold)
        spaceLabel.textColor = Design.Palette.ink
        separator.wantsLayer = true
        separator.layer?.backgroundColor = Design.Palette.rule.cgColor
        separator.translatesAutoresizingMaskIntoConstraints = false
        icon.symbolConfiguration = .init(pointSize: 10, weight: .semibold)
        label.font = Design.Typography.small
        label.textColor = Design.Palette.ink(.secondary)

        stack = NSStackView(views: [spaceMark, spaceLabel, separator, icon, label])
        stack.spacing = 7
        stack.setCustomSpacing(10, after: spaceLabel)
        stack.setCustomSpacing(10, after: separator)
        stack.setCustomSpacing(5, after: icon)
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 13)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 28),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            spaceMark.widthAnchor.constraint(equalToConstant: 3), spaceMark.heightAnchor.constraint(equalToConstant: 11),
            separator.widthAnchor.constraint(equalToConstant: 1), separator.heightAnchor.constraint(equalToConstant: 12),
        ])
    }

    required init?(coder: NSCoder) { fatalError("non utilisé") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Couleur du symbole : monochrome, sauf les avertissements (rouge, orange) en brique sourde.
    static func symbolColor(for tint: NSColor) -> NSColor {
        tint == .systemRed || tint == .systemOrange ? Design.Palette.space(7) : Design.Palette.ink(.secondary)
    }

    /// - Parameter space: nom et couleur de l'espace à rappeler (deux comptes Zoho se ressemblent).
    /// - Parameter duration: durée d'affichage ; un message d'attente reste jusqu'au message suivant.
    func show(text: String, symbol: String, tint: NSColor, space: (name: String, color: NSColor)? = nil,
              duration: Duration = .milliseconds(1500)) {
        let update = {
            self.label.stringValue = text
            self.icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            self.icon.contentTintColor = Self.symbolColor(for: tint)
            for view in [self.spaceMark, self.spaceLabel, self.separator] { view.isHidden = space == nil }
            self.spaceMark.layer?.backgroundColor = space?.color.cgColor
            self.spaceLabel.stringValue = space?.name ?? ""
        }
        if isShown {
            // Déjà affichée : le texte change sur place (fondu court), elle ne redescend pas.
            Design.Motion.animate(.fast, { self.stack.animator().alphaValue = 0 }) { [weak self] in
                guard let self else { return }
                update()
                Design.Motion.animate(.fast) { self.stack.animator().alphaValue = 1 }
            }
        } else {
            update()
            stack.alphaValue = 1
            isHidden = false
            isShown = true
            slide(fromAbove: true)
        }
        hideTask?.cancel()
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled, let self else { return }
            self.isShown = false
            self.slide(fromAbove: false)
        }
    }

    /// Descend du haut (ou y remonte) en fondu ; « Réduire les animations » : fondu seul.
    private func slide(fromAbove appearing: Bool) {
        let distance: CGFloat = 36
        if Design.Motion.allowsMovement(), let layer {
            let move = CABasicAnimation(keyPath: "transform")
            // La fenêtre n'est pas retournée : dans le repère du calque, y monte.
            move.fromValue = CATransform3DMakeTranslation(0, appearing ? distance : 0, 0)
            move.toValue = CATransform3DMakeTranslation(0, appearing ? 0 : distance, 0)
            move.duration = Design.Motion.duration(.medium)
            move.timingFunction = Design.Motion.curve
            move.fillMode = .forwards
            move.isRemovedOnCompletion = appearing
            layer.add(move, forKey: "vision.slide")
        }
        Design.Motion.animate(.medium, { self.animator().alphaValue = appearing ? 1 : 0 }) { [weak self] in
            guard let self, !appearing, !self.isShown else { return }
            self.isHidden = true
            self.layer?.removeAnimation(forKey: "vision.slide")
        }
    }
}
