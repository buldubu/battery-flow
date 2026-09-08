import AppKit
import Testing
@testable import BatteryFlow

@MainActor
struct BatteryMenuLabelTests {
    @Test func sailingIsOneTemplateImageWithBothSymbols() throws {
        let snapshot = PowerSnapshot(state: .paused, chargePercent: 80)
        let image = BatteryMenuImage.image(for: snapshot, showPercentage: false)
        #expect(image.isTemplate)
        #expect(image.size == NSSize(width: 45, height: 18))
        let data = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: data))
        #expect(hasInk(bitmap, from: 0, to: 25, imageWidth: image.size.width))
        #expect(hasInk(bitmap, from: 29, to: 45, imageWidth: image.size.width))
        #expect(snapshot.state.title == "Sailing")
        #expect(snapshot.state.icon == "sailboat.fill")
    }

    @Test func onlyFreshPausedStateShowsSailboat() {
        for state in [PowerState.onBattery, .charged, .supplementing, .unavailable] {
            let image = BatteryMenuImage.image(for: PowerSnapshot(state: state, chargePercent: 80), showPercentage: false)
            #expect(image.size.width == 25)
        }
        let stale = PowerSnapshot(state: .paused, chargePercent: 80, isStale: true)
        #expect(BatteryMenuImage.image(for: stale, showPercentage: false).size.width == 25)
    }

    @Test func chargingDrawsBoltAndUpdatesWhenStateChanges() throws {
        let charging = PowerSnapshot(state: .charging, chargePercent: 80)
        let sailing = PowerSnapshot(state: .paused, chargePercent: 80)
        #expect(BatteryMenuImage.badgeSymbol(for: charging) == "bolt.fill")
        #expect(BatteryMenuImage.badgeSymbol(for: sailing) == "sailboat.fill")
        let image = BatteryMenuImage.image(for: charging, showPercentage: false)
        #expect(image.isTemplate)
        #expect(image.size.width == 45)
        let data = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: data))
        #expect(hasInk(bitmap, from: 0, to: 25, imageWidth: image.size.width))
        #expect(hasInk(bitmap, from: 29, to: 45, imageWidth: image.size.width))
        #expect(data != BatteryMenuImage.image(for: sailing, showPercentage: false).tiffRepresentation)
        #expect(BatteryMenuImage.badgeSymbol(for: charging.stale(message: "Read failed")) == nil)
        #expect(BatteryMenuImage.image(for: charging.stale(message: "Read failed"), showPercentage: false).size.width == 25)
        let percentageImage = BatteryMenuImage.image(for: charging, showPercentage: true)
        let percentageData = try #require(percentageImage.tiffRepresentation)
        let percentageBitmap = try #require(NSBitmapImageRep(data: percentageData))
        #expect(hasInk(percentageBitmap, from: 49, to: percentageImage.size.width, imageWidth: percentageImage.size.width))
    }

    @Test func percentageIsDrawnInsideNativeImage() throws {
        let snapshot = PowerSnapshot(state: .paused, chargePercent: 80)
        let image = BatteryMenuImage.image(for: snapshot, showPercentage: true)
        #expect(image.size.width > 49)
        let data = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: data))
        #expect(hasInk(bitmap, from: 49, to: image.size.width, imageWidth: image.size.width))
        #expect(image === BatteryMenuImage.image(for: snapshot, showPercentage: true))
        #expect(image !== BatteryMenuImage.image(for: snapshot, showPercentage: false))
    }

    @Test func batteryChargeChangesRenderedImage() {
        let low = BatteryMenuImage.image(for: PowerSnapshot(state: .onBattery, chargePercent: 10), showPercentage: false)
        let high = BatteryMenuImage.image(for: PowerSnapshot(state: .onBattery, chargePercent: 90), showPercentage: false)
        #expect(low.tiffRepresentation != high.tiffRepresentation)
    }

    private func hasInk(_ bitmap: NSBitmapImageRep, from: CGFloat, to: CGFloat, imageWidth: CGFloat) -> Bool {
        let scale = CGFloat(bitmap.pixelsWide) / imageWidth
        for x in Int(from * scale)..<Int(to * scale) {
            for y in 0..<bitmap.pixelsHigh {
                if (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 { return true }
            }
        }
        return false
    }
}
