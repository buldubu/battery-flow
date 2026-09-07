import AppKit
import QuartzCore
import Testing
@testable import BatteryFlow

@MainActor
struct FlowAnimationTests {
    @Test func motionStopsForPauseStaleDataAndTeardown() {
        let view = FlowLinesView()
        view.frame = NSRect(x: 0, y: 0, width: 488, height: 212)
        let snapshot = PowerMath.snapshot(from: telemetry())
        func movingStrokes() -> [CALayer] {
            (view.layer?.sublayers ?? []).filter { $0.animation(forKey: "flow") != nil }
        }
        view.update(snapshot: snapshot, isAnimating: true)
        #expect(!movingStrokes().isEmpty)
        view.update(snapshot: snapshot, isAnimating: false)
        #expect(movingStrokes().isEmpty)
        view.update(snapshot: snapshot, isAnimating: true)
        #expect(!movingStrokes().isEmpty)
        view.update(snapshot: snapshot.stale(message: "Unavailable"), isAnimating: false)
        #expect(movingStrokes().isEmpty)
        let visibleFlows = (view.layer?.sublayers ?? []).compactMap { $0 as? CAShapeLayer }
            .filter { $0.lineDashPattern != nil && !$0.isHidden }
        #expect(visibleFlows.isEmpty)
        view.update(snapshot: snapshot, isAnimating: true)
        view.stopAnimation()
        #expect(movingStrokes().isEmpty)
    }
}
