import AppKit
import QuartzCore
import SwiftUI

/// Core Animation moves the dashes; SwiftUI updates geometry only with new readings.
struct PowerFlowLines: NSViewRepresentable {
    let snapshot: PowerSnapshot
    let isAnimating: Bool

    func makeNSView(context: Context) -> FlowLinesView { FlowLinesView() }
    func updateNSView(_ view: FlowLinesView, context: Context) {
        view.update(snapshot: snapshot, isAnimating: isAnimating)
    }
    static func dismantleNSView(_ view: FlowLinesView, coordinator: ()) {
        view.stopAnimation()
    }
}

final class FlowLinesView: NSView {
    private let structure = [CAShapeLayer(), CAShapeLayer()]
    private let flows = [CAShapeLayer(), CAShapeLayer(), CAShapeLayer()]
    private var snapshot = PowerSnapshot.empty
    private var isAnimating = false
    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer = CALayer()
        for stroke in structure + flows {
            stroke.fillColor = nil
            stroke.lineCap = .round
            layer?.addSublayer(stroke)
        }
        for stroke in flows { stroke.lineDashPattern = [12, 9] }
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { nil }

    func update(snapshot: PowerSnapshot, isAnimating: Bool) {
        self.snapshot = snapshot
        self.isAnimating = isAnimating
        render()
    }
    override func layout() {
        super.layout()
        render()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        render()
    }
    func stopAnimation() {
        for stroke in flows { stroke.removeAllAnimations() }
    }
    private func render() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let adapter = CGPoint(x: 62, y: 62)
        let mac = CGPoint(x: bounds.width - 62, y: 62)
        let battery = CGPoint(x: bounds.width / 2, y: bounds.height - 46)
        let direct = path(from: adapter, to: mac, control: CGPoint(x: bounds.width / 2, y: 42))
        let discharge = path(from: battery, to: mac,
                             control: CGPoint(x: bounds.width * 0.7, y: bounds.height * 0.7))

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        for stroke in structure + flows { stroke.frame = bounds }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            structure[0].path = direct
            structure[0].lineWidth = 4
            structure[0].strokeColor = NSColor.secondaryLabelColor.withAlphaComponent(0.16).cgColor
            structure[1].path = discharge
            structure[1].lineWidth = 3
            structure[1].strokeColor = NSColor.secondaryLabelColor.withAlphaComponent(0.12).cgColor

            let powerIsCurrent = !snapshot.isAwaitingPowerData && snapshot.quality != .inconsistent && !snapshot.isStale
            let directPower: Double
            if powerIsCurrent, snapshot.externalConnected == true,
               let adapterPower = snapshot.adapterPowerWatts, let systemPower = snapshot.systemPowerWatts {
                directPower = min(adapterPower, systemPower)
            } else { directPower = 0 }
            configure(flows[0], path: direct, power: directPower, color: .systemBlue)
            configure(flows[1], path: path(from: adapter, to: battery,
                control: CGPoint(x: bounds.width * 0.34, y: bounds.height * 0.7)),
                power: powerIsCurrent && snapshot.externalConnected == true && (snapshot.batteryPowerWatts ?? 0) > 0.2
                    ? snapshot.batteryPowerWatts ?? 0 : 0, color: .systemGreen)
            configure(flows[2], path: discharge,
                power: powerIsCurrent && (snapshot.batteryPowerWatts ?? 0) < -0.2 ? -(snapshot.batteryPowerWatts ?? 0) : 0,
                color: .systemOrange)
        }
    }
    private func configure(_ stroke: CAShapeLayer, path: CGPath, power: Double, color: NSColor) {
        stroke.path = path
        stroke.isHidden = power <= 0.05
        stroke.strokeColor = color.cgColor
        stroke.lineWidth = min(max(3 + sqrt(max(0, power)) * 0.8, 4), 11)
        if isAnimating && !stroke.isHidden {
            if stroke.animation(forKey: "flow") == nil {
                let animation = CABasicAnimation(keyPath: "lineDashPhase")
                animation.fromValue = 0
                animation.toValue = -21
                animation.duration = 21.0 / 28.0
                animation.repeatCount = .infinity
                animation.timingFunction = CAMediaTimingFunction(name: .linear)
                stroke.add(animation, forKey: "flow")
            }
        } else {
            stroke.removeAnimation(forKey: "flow")
            stroke.lineDashPhase = 0
        }
    }
    private func path(from: CGPoint, to: CGPoint, control: CGPoint) -> CGPath {
        let path = CGMutablePath()
        path.move(to: from)
        path.addQuadCurve(to: to, control: control)
        return path
    }
}
