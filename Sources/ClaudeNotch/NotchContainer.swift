import AppKit
import QuartzCore

/// The notch silhouette, drawn and animated by Core Animation.
///
/// The black shape, its shadow and the mask that reveals the SwiftUI content all share one path and one
/// spring, so they can never drift apart, and the animation runs in the render server at the display's
/// full refresh rate (120 Hz on ProMotion) no matter how busy the app's main thread is.
final class NotchContainerView: NSView {
    let host: NSView
    private let background = NotchLayerView()
    private let clip = NSView()
    private let mask = CAShapeLayer()

    init(frame: NSRect, host: NSView) {
        self.host = host
        super.init(frame: frame)
        wantsLayer = true

        background.frame = bounds
        background.autoresizingMask = [.width, .height]
        addSubview(background)

        clip.frame = bounds
        clip.autoresizingMask = [.width, .height]
        clip.wantsLayer = true
        mask.frame = bounds
        clip.layer?.mask = mask
        addSubview(clip)

        host.frame = clip.bounds
        host.autoresizingMask = [.width, .height]
        clip.addSubview(host)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    #if DEBUG
    var debugShapeLayer: CAShapeLayer { background.shape }
    #endif

    // Layer-hosting views don't follow the screen's scale on their own: keep edges sharp on Retina.
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        mask.contentsScale = scale
        background.shape.contentsScale = scale
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        viewDidChangeBackingProperties()
    }

    /// Shape the notch around `body` (the black area, in this view's coordinates, y up).
    /// `growing` picks the spring; `raised` (the panel is open) shows the shadow.
    func setShape(body: CGRect, topRadius: CGFloat, bottomRadius: CGFloat, growing: Bool, raised: Bool, animated: Bool) {
        let path = Self.path(body: body, top: topRadius, bottom: bottomRadius)
        // Growing gets a small Dynamic-Island bounce; shrinking settles without one.
        let spring = animated ? Self.spring(response: growing ? 0.40 : 0.30, bounce: growing ? 0.16 : 0) : nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        Self.set(path, on: mask, keyPath: "path", spring: spring)
        Self.set(path, on: background.shape, keyPath: "path", spring: spring)
        Self.set(path, on: background.shape, keyPath: "shadowPath", spring: spring)
        let opacity: Float = raised ? 0.45 : 0
        if animated, background.shape.shadowOpacity != opacity {
            let fade = CABasicAnimation(keyPath: "shadowOpacity")
            fade.fromValue = background.shape.presentation()?.shadowOpacity ?? background.shape.shadowOpacity
            fade.toValue = opacity
            fade.duration = raised ? 0.35 : 0.18
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            background.shape.add(fade, forKey: "shadowOpacity")
        }
        background.shape.shadowOpacity = opacity
        CATransaction.commit()
    }

    private static func set(_ path: CGPath, on layer: CAShapeLayer, keyPath: String, spring: CASpringAnimation?) {
        // Start from where the shape is on screen right now, so interrupting an animation is seamless.
        let current: CGPath? = keyPath == "path"
            ? (layer.presentation()?.path ?? layer.path)
            : (layer.presentation()?.shadowPath ?? layer.shadowPath)
        if keyPath == "path" { layer.path = path } else { layer.shadowPath = path }
        guard let spring, let current else { return }
        let animation = spring.copy() as! CASpringAnimation
        animation.keyPath = keyPath
        animation.fromValue = current
        animation.toValue = path
        layer.add(animation, forKey: keyPath)
    }

    /// A critically damped (or slightly bouncy) spring described like SwiftUI's: response and bounce.
    private static func spring(response: Double, bounce: Double) -> CASpringAnimation {
        let spring = CASpringAnimation()
        spring.mass = 1
        spring.stiffness = pow(2 * .pi / response, 2)
        spring.damping = 4 * .pi * (1 - bounce) / response
        spring.duration = spring.settlingDuration
        spring.timingFunction = CAMediaTimingFunction(name: .linear)
        spring.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        return spring
    }

    /// Flared top corners that melt into the bezel, rounded bottom corners. Always the same
    /// sequence of elements, so any two shapes interpolate cleanly.
    static func path(body r: CGRect, top t: CGFloat, bottom b: CGFloat) -> CGPath {
        let b = max(0, min(b, r.height - t, r.width / 2))
        let top = r.maxY, bottom = r.minY
        let p = CGMutablePath()
        p.move(to: CGPoint(x: r.minX - t, y: top))
        p.addQuadCurve(to: CGPoint(x: r.minX, y: top - t), control: CGPoint(x: r.minX, y: top))
        p.addLine(to: CGPoint(x: r.minX, y: bottom + b))
        p.addQuadCurve(to: CGPoint(x: r.minX + b, y: bottom), control: CGPoint(x: r.minX, y: bottom))
        p.addLine(to: CGPoint(x: r.maxX - b, y: bottom))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: bottom + b), control: CGPoint(x: r.maxX, y: bottom))
        p.addLine(to: CGPoint(x: r.maxX, y: top - t))
        p.addQuadCurve(to: CGPoint(x: r.maxX + t, y: top), control: CGPoint(x: r.maxX, y: top))
        p.closeSubpath()
        return p
    }
}

/// A layer-hosting view whose layer is the black notch shape.
private final class NotchLayerView: NSView {
    let shape = CAShapeLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        shape.fillColor = NSColor.black.cgColor
        shape.shadowColor = NSColor.black.cgColor
        shape.shadowRadius = 16
        shape.shadowOffset = CGSize(width: 0, height: -6)
        shape.shadowOpacity = 0
        layer = shape
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
