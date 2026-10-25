import AppKit
import QuartzCore

/// Brightness indicator modelled on the macOS 26+ system panel: top right under the menu bar,
/// Liquid Glass, springs in from the corner, the level glides between values.
@MainActor
final class HUD {
    static let shared = HUD()

    private let size = NSSize(width: 292, height: 64)
    private var panel: NSPanel?
    private var glass: NSView!
    private let title = NSTextField(labelWithString: "")
    private let percent = NSTextField(labelWithString: "")
    private let percentBox = NSView()
    private let subtitle = NSTextField(labelWithString: "")
    private let level = LevelView()
    private let low = NSImageView()
    private let high = NSImageView()
    private var hideWork: DispatchWorkItem?
    private var visible = false

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false   // the glass draws its own
        p.level = .statusBar
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        let content = NSView(frame: NSRect(origin: .zero, size: size))
        title.font = .systemFont(ofSize: 13, weight: .bold)
        title.textColor = .labelColor
        title.lineBreakMode = .byTruncatingTail
        percent.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        percent.textColor = .secondaryLabelColor
        percent.alignment = .right
        percent.wantsLayer = true
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.textColor = .secondaryLabelColor
        for (v, name, pt) in [(low, "sun.min.fill", 11.0), (high, "sun.max.fill", 15.0)] {
            v.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: pt, weight: .regular))
            v.contentTintColor = .secondaryLabelColor
        }
        title.frame = NSRect(x: 16, y: size.height - 30, width: size.width - 80, height: 18)
        // digits roll inside this clipping box, not over the sun icon
        percentBox.wantsLayer = true
        percentBox.layer?.masksToBounds = true
        percentBox.frame = NSRect(x: size.width - 66, y: size.height - 30, width: 50, height: 18)
        percent.frame = percentBox.bounds
        percentBox.addSubview(percent)
        subtitle.frame = NSRect(x: 16, y: 12, width: size.width - 32, height: 18)
        low.frame = NSRect(x: 14, y: 14, width: 18, height: 18)
        high.frame = NSRect(x: size.width - 34, y: 13, width: 20, height: 20)
        level.frame = NSRect(x: 42, y: 8, width: size.width - 84, height: 26)
        [title, percentBox, subtitle, low, high, level].forEach(content.addSubview)

        // container stays put; the glass inside is what we scale and fade
        let container = NSView(frame: content.frame)
        container.wantsLayer = true
        if #available(macOS 26.0, *) {
            let g = NSGlassEffectView(frame: content.frame)
            g.cornerRadius = 20
            g.contentView = content
            glass = g
        } else {
            let fx = NSVisualEffectView(frame: content.frame)
            fx.material = .hudWindow
            fx.blendingMode = .behindWindow
            fx.state = .active
            fx.wantsLayer = true
            fx.layer?.cornerRadius = 20
            fx.layer?.masksToBounds = true
            fx.addSubview(content)
            glass = fx
        }
        glass.wantsLayer = true
        container.addSubview(glass)
        p.contentView = container
        return p
    }

    func showBrightness(_ value: Int, on screen: NSScreen?) {
        show(on: screen, title: screen?.localizedName ?? "LG", subtitle: nil, value: value)
    }

    func showMessage(_ text: String, detail: String? = nil, seconds: Double = 2.5) {
        show(on: SystemInfo.screenUnderMouse(), title: text, subtitle: detail, value: nil, seconds: seconds)
    }

    private func show(on screen: NSScreen?, title t: String, subtitle s: String?, value: Int?, seconds: Double = 1.6) {
        let p = panel ?? makePanel()
        panel = p
        title.stringValue = t
        subtitle.stringValue = s ?? ""
        subtitle.isHidden = value != nil
        [low, high, level, percentBox].forEach { $0.isHidden = value == nil }

        let vf = (screen ?? NSScreen.main)?.visibleFrame ?? .zero
        p.setFrameOrigin(NSPoint(x: vf.maxX - size.width - 10, y: vf.maxY - size.height - 8))

        let appearing = !visible
        if let value {
            if appearing { level.set(value, animated: false) } else { level.set(value, animated: true) }
            setPercent(value, animated: !appearing)
        }
        if appearing { appear(p) }

        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.disappear() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func setPercent(_ value: Int, animated: Bool) {
        let text = "\(value)%"
        guard percent.stringValue != text else { return }
        if animated, let layer = percent.layer {
            let t = CATransition()
            t.type = .push
            t.subtype = value > (Int(percent.stringValue.dropLast()) ?? 0) ? .fromTop : .fromBottom
            t.duration = 0.18
            t.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(t, forKey: "digits")
        }
        percent.stringValue = text
    }

    // MARK: motion

    /// Springs out of the top-right corner, like the system panel.
    private func appear(_ p: NSPanel) {
        visible = true
        guard let layer = glass.layer else { return }
        layer.removeAllAnimations()
        // scale around the top-right corner
        let b = glass.bounds
        layer.anchorPoint = CGPoint(x: 1, y: 1)
        layer.position = CGPoint(x: b.maxX, y: b.maxY)
        layer.opacity = 1
        layer.transform = CATransform3DIdentity
        p.alphaValue = 1
        p.orderFrontRegardless()

        let scale = CASpringAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.82
        scale.toValue = 1
        scale.mass = 1
        scale.stiffness = 320
        scale.damping = 22
        scale.initialVelocity = 2
        scale.duration = scale.settlingDuration

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.16
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)

        let blur = CABasicAnimation(keyPath: "position.y")
        blur.fromValue = b.maxY + 6
        blur.toValue = b.maxY
        blur.duration = 0.28
        blur.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)

        layer.add(scale, forKey: "in-scale")
        layer.add(fade, forKey: "in-fade")
        layer.add(blur, forKey: "in-drop")
    }

    private func disappear() {
        guard visible, let p = panel, let layer = glass.layer else { return }
        visible = false
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, !self.visible else { return }
            p.orderOut(nil)
            layer.removeAllAnimations()
            layer.opacity = 1
            layer.transform = CATransform3DIdentity
        }
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 1
        scale.toValue = 0.94
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        for a in [scale, fade] {
            a.duration = 0.3
            a.timingFunction = CAMediaTimingFunction(name: .easeIn)
            a.fillMode = .forwards
            a.isRemovedOnCompletion = false
        }
        layer.add(scale, forKey: "out-scale")
        layer.add(fade, forKey: "out-fade")
        CATransaction.commit()
    }
}

/// Thin track, fill that glides with a spring, 17 tick dots: the system level indicator.
final class LevelView: NSView {
    private let track = CALayer()
    private let fill = CALayer()
    private let dots = CAShapeLayer()
    private(set) var value = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(track)
        layer?.addSublayer(fill)
        layer?.addSublayer(dots)
        fill.anchorPoint = CGPoint(x: 0, y: 0.5)
        track.cornerRadius = 2
        fill.cornerRadius = 2
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let y = bounds.height - 9
        track.frame = CGRect(x: 0, y: y - 2, width: bounds.width, height: 4)
        fill.bounds = CGRect(x: 0, y: 0, width: fillWidth(value), height: 4)
        fill.position = CGPoint(x: 0, y: y)
        let path = CGMutablePath()
        for i in 0...16 {
            let x = bounds.width * CGFloat(i) / 16
            path.addEllipse(in: CGRect(x: x - 0.9, y: y - 11, width: 1.8, height: 1.8))
        }
        dots.path = path
        updateColors()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            track.backgroundColor = NSColor.labelColor.withAlphaComponent(0.18).cgColor
            fill.backgroundColor = NSColor.labelColor.cgColor
            dots.fillColor = NSColor.secondaryLabelColor.cgColor
        }
    }

    private func fillWidth(_ v: Int) -> CGFloat { max(4, bounds.width * CGFloat(v) / 100) }

    func set(_ v: Int, animated: Bool) {
        let from = fill.presentation()?.bounds.width ?? fillWidth(value)
        value = v
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.bounds.size.width = fillWidth(v)
        CATransaction.commit()
        guard animated else { return }
        let a = CASpringAnimation(keyPath: "bounds.size.width")
        a.fromValue = from
        a.toValue = fillWidth(v)
        a.stiffness = 420
        a.damping = 34
        a.duration = a.settlingDuration
        fill.add(a, forKey: "level")
    }
}
