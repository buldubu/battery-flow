import AppKit
import SwiftUI

struct BatteryMenuLabel: View {
    @ObservedObject var monitor: PowerMonitor
    @ObservedObject var preferences: AppPreferences

    var body: some View {
        // MenuBarExtra extracts a native status-item image; sibling images are not a reliable label.
        Image(nsImage: BatteryMenuImage.image(for: monitor.snapshot, showPercentage: preferences.showPercentage))
            .renderingMode(.template)
            .accessibilityLabel("Battery Flow, \(monitor.snapshot.chargeText), \(monitor.snapshot.state.title)")
            .help("Battery Flow — \(monitor.snapshot.state.title), \(monitor.snapshot.chargeText)")
    }
}

@MainActor
enum BatteryMenuImage {
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 64
        return cache
    }()

    static func image(for snapshot: PowerSnapshot, showPercentage: Bool) -> NSImage {
        let symbol = symbol(for: snapshot)
        let charging = snapshot.state == .charging && !snapshot.isStale
        let percentage = showPercentage ? snapshot.chargeText : ""
        let key = "\(symbol)|\(percentage)|\(charging ? snapshot.chargeText : "")" as NSString
        if let cached = cache.object(forKey: key) { return cached }

        let text = NSAttributedString(string: percentage, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular),
            .foregroundColor: NSColor.black
        ])
        let iconWidth: CGFloat = symbol == "sailboat.fill" ? 18 : 25
        let width = iconWidth + (showPercentage ? 4 + ceil(text.size().width) : 0)
        let image = NSImage(size: NSSize(width: width, height: 18))
        image.lockFocus()
        if charging {
            drawChargingBattery(percent: snapshot.chargePercent)
        } else {
            drawSymbol(symbol, in: NSRect(x: 0, y: 0, width: iconWidth, height: 18))
        }
        if showPercentage {
            text.draw(at: NSPoint(x: iconWidth + 4, y: floor((18 - text.size().height) / 2)))
        }
        image.unlockFocus()
        image.isTemplate = true
        cache.setObject(image, forKey: key)
        return image
    }

    static func symbol(for snapshot: PowerSnapshot) -> String {
        guard snapshot.state != .unavailable, !snapshot.isStale else { return "questionmark.circle" }
        return snapshot.state == .paused ? "sailboat.fill" : snapshot.batteryIcon
    }

    private static func drawChargingBattery(percent: Int?) {
        NSColor.black.setFill()
        NSColor.black.setStroke()
        let outline = NSBezierPath(roundedRect: NSRect(x: 0.75, y: 3, width: 21.5, height: 12),
                                   xRadius: 2.5, yRadius: 2.5)
        outline.lineWidth = 1.4
        outline.stroke()
        NSBezierPath(roundedRect: NSRect(x: 23.4, y: 6.5, width: 1.6, height: 5),
                     xRadius: 0.8, yRadius: 0.8).fill()

        let fraction = CGFloat(percent.flatMap { (0...100).contains($0) ? $0 : nil } ?? 0) / 100
        let interior = NSRect(x: 3, y: 5.25, width: 17, height: 7.5)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: interior, xRadius: 0.8, yRadius: 0.8).addClip()
        NSRect(x: interior.minX, y: interior.minY, width: interior.width * fraction, height: interior.height).fill()
        NSGraphicsContext.restoreGraphicsState()

        // Clear a narrow halo so the centered bolt stays legible across filled and empty areas.
        let bolt = NSBezierPath()
        bolt.move(to: NSPoint(x: 13.2, y: 16.5))
        bolt.line(to: NSPoint(x: 7.5, y: 8))
        bolt.line(to: NSPoint(x: 10.7, y: 8))
        bolt.line(to: NSPoint(x: 9, y: 1.5))
        bolt.line(to: NSPoint(x: 15.5, y: 10.5))
        bolt.line(to: NSPoint(x: 12.1, y: 10.5))
        bolt.close()
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.compositingOperation = .destinationOut
        bolt.lineWidth = 1.6
        bolt.lineJoinStyle = .round
        bolt.stroke()
        bolt.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSColor.black.setFill()
        bolt.fill()
    }

    private static func drawSymbol(_ name: String, in bounds: NSRect) {
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .regular)) else { return }
        let scale = min(bounds.width / symbol.size.width, bounds.height / symbol.size.height)
        let size = NSSize(width: symbol.size.width * scale, height: symbol.size.height * scale)
        symbol.draw(in: NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                              width: size.width, height: size.height))
    }
}
