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

/// Indicateur de chargement : « le trait », même motif que la fente de la barre Cmd+T.
///
/// Un trait de 2 pt, de la couleur de l'espace, collé au bord haut. Il naît au centre et s'élargit vers les deux
/// bords à mesure que la page se charge. Chargement fini : il atteint les bords, puis se rétracte en un point au
/// centre et disparaît. Il n'apparaît qu'après 150 ms : un chargement éclair ne fait rien clignoter.
@MainActor
final class LoadingLineView: NSView {
    static let height: CGFloat = 2
    /// Largeur minimale affichée : le trait se voit dès le début, avant que WebKit ne donne de progression.
    static let minimumFraction = 0.08

    private let line = CALayer()
    private var showTask: Task<Void, Never>?
    /// Avancée lente pendant que la page attend son serveur (WebKit ne bouge sa progression qu'au fil des octets).
    private var creepTask: Task<Void, Never>?
    private var isShowing = false
    private var fraction = 0.0
    /// Numéro de la dernière animation : une fin d'animation dépassée (nouveau chargement entre-temps) ne fait rien.
    private var token = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        line.cornerRadius = Self.height / 2
        line.opacity = 0
        layer?.addSublayer(line)
    }

    required init?(coder: NSCoder) { fatalError("non utilisé") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Avancée lente : chaque pas réduit de 6 % l'écart restant jusqu'à 90 % ; jamais au-delà tant que ça charge.
    static func creep(_ fraction: Double) -> Double {
        fraction >= 0.9 ? fraction : fraction + (0.9 - fraction) * 0.06
    }

    /// Cadre du trait pour une fraction de la largeur, toujours centré.
    static func lineFrame(fraction: Double, in bounds: CGRect) -> CGRect {
        let width = bounds.width * CGFloat(min(max(fraction, 0), 1))
        return CGRect(x: (bounds.width - width) / 2, y: 0, width: width, height: height)
    }

    /// État de chargement de la page affichée. `reset` : autre page affichée, on repart de zéro sans animation.
    func update(loading: Bool, progress: Double, color: NSColor, reset: Bool = false) {
        line.backgroundColor = color.cgColor
        if reset {
            showTask?.cancel()
            showTask = nil
            creepTask?.cancel()
            creepTask = nil
            fraction = 0
            isShowing = false
            token += 1
            place(fraction: 0, opacity: 0, speed: nil)
        }
        if loading {
            fraction = max(fraction, progress, Self.minimumFraction)
            if isShowing {
                place(fraction: fraction, opacity: 1, speed: .medium)
            } else if showTask == nil {
                showTask = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(150))
                    guard let self, !Task.isCancelled else { return }
                    self.showTask = nil
                    self.isShowing = true
                    self.token += 1
                    // Le trait naît au centre : il part d'un point.
                    self.place(fraction: 0, opacity: 1, speed: nil)
                    self.place(fraction: self.fraction, opacity: 1, speed: .medium)
                    self.startCreeping()
                }
            }
        } else {
            showTask?.cancel()
            showTask = nil
            creepTask?.cancel()
            creepTask = nil
            fraction = 0
            guard isShowing else { return }
            isShowing = false
            token += 1
            let done = token
            // Il atteint les deux bords, puis se rétracte au centre et s'éteint.
            place(fraction: 1, opacity: 1, speed: .fast) { [weak self] in
                guard let self, self.token == done else { return }
                if Design.Motion.allowsMovement() {
                    self.place(fraction: 0, opacity: 1, speed: .medium) { [weak self] in
                        guard let self, self.token == done else { return }
                        self.place(fraction: 0, opacity: 0, speed: nil)
                    }
                } else {
                    self.place(fraction: 1, opacity: 0, speed: .medium)
                }
            }
        }
    }

    private func startCreeping() {
        creepTask?.cancel()
        creepTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(300))
                guard let self, !Task.isCancelled, self.isShowing else { return }
                self.fraction = Self.creep(self.fraction)
                self.place(fraction: self.fraction, opacity: 1, speed: .medium)
            }
        }
    }

    private func place(fraction: Double, opacity: Float, speed: Design.Motion.Speed?, then next: (@MainActor () -> Void)? = nil) {
        CATransaction.begin()
        if let speed {
            CATransaction.setAnimationDuration(Design.Motion.duration(speed))
            CATransaction.setAnimationTimingFunction(Design.Motion.curve)
        } else {
            CATransaction.setDisableActions(true)
        }
        if let next { CATransaction.setCompletionBlock { MainActor.assumeIsolated { next() } } }
        line.frame = Self.lineFrame(fraction: fraction, in: bounds)
        line.opacity = opacity
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        // Fenêtre redimensionnée : le trait reste centré, à sa fraction.
        guard line.animationKeys() == nil else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        line.frame = Self.lineFrame(fraction: line.opacity > 0 ? fraction : 0, in: bounds)
        CATransaction.commit()
    }
}
