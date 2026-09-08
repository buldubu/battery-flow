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
        let symbol = snapshot.state == .unavailable || snapshot.isStale ? "questionmark.circle" : snapshot.batteryIcon
        let sailing = snapshot.state == .paused && !snapshot.isStale
        let percentage = showPercentage ? snapshot.chargeText : ""
        let key = "\(symbol)|\(sailing)|\(percentage)" as NSString
        if let cached = cache.object(forKey: key) { return cached }

        let text = NSAttributedString(string: percentage, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular),
            .foregroundColor: NSColor.black
        ])
        let iconWidth: CGFloat = sailing ? 45 : 25
        let width = iconWidth + (showPercentage ? 4 + ceil(text.size().width) : 0)
        let image = NSImage(size: NSSize(width: width, height: 18))
        image.lockFocus()
        drawSymbol(symbol, in: NSRect(x: 0, y: 0, width: 25, height: 18))
        if sailing {
            drawSymbol("sailboat.fill", in: NSRect(x: 29, y: 0, width: 16, height: 18))
        }
        if showPercentage {
            text.draw(at: NSPoint(x: iconWidth + 4, y: floor((18 - text.size().height) / 2)))
        }
        image.unlockFocus()
        image.isTemplate = true
        cache.setObject(image, forKey: key)
        return image
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
