import AppKit
import Testing
@testable import BatteryFlow

@MainActor
struct BatteryMenuLabelTests {
    @Test func connectingShowsNeutralPlug() throws {
        let snapshot = PowerSnapshot(state: .paused, chargePercent: 80, isConnecting: true)
        #expect(BatteryMenuImage.symbol(for: snapshot) == "powerplug.fill")
        let image = BatteryMenuImage.image(for: snapshot, showPercentage: false)
        let data = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: data))
        #expect(hasInk(bitmap, from: 0, to: image.size.width, imageWidth: image.size.width))
        #expect(BatteryMenuImage.symbol(for: snapshot.stale(message: "Read failed")) == "questionmark.circle")
    }

    @Test func sailingShowsOnlyTheSailboat() throws {
        let snapshot = PowerSnapshot(state: .paused, chargePercent: 80)
        let image = BatteryMenuImage.image(for: snapshot, showPercentage: false)
        #expect(image.isTemplate)
        #expect(image.size == NSSize(width: 18, height: 18))
        let data = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: data))
        #expect(hasInk(bitmap, from: 0, to: 18, imageWidth: image.size.width))
        #expect(BatteryMenuImage.symbol(for: snapshot) == "sailboat.fill")
        let otherCharge = PowerSnapshot(state: .paused, chargePercent: 20)
        #expect(image === BatteryMenuImage.image(for: otherCharge, showPercentage: false))
        #expect(snapshot.state.title == "Sailing")
        #expect(snapshot.state.icon == "sailboat.fill")
    }

    @Test func onlyFreshPausedStateShowsSailboat() {
        for state in [PowerState.onBattery, .charging, .charged, .supplementing, .unavailable] {
            let image = BatteryMenuImage.image(for: PowerSnapshot(state: state, chargePercent: 80), showPercentage: false)
            #expect(image.size.width == 25)
        }
        let stale = PowerSnapshot(state: .paused, chargePercent: 80, isStale: true)
        #expect(BatteryMenuImage.image(for: stale, showPercentage: false).size.width == 25)
    }

    @Test func chargingUsesBoltInsideBatteryWithoutExtraWidth() throws {
        let charging = PowerSnapshot(state: .charging, chargePercent: 80)
        let battery = PowerSnapshot(state: .onBattery, chargePercent: 80)
        let image = BatteryMenuImage.image(for: charging, showPercentage: false)
        #expect(image.isTemplate)
        #expect(image.size == BatteryMenuImage.image(for: battery, showPercentage: false).size)
        let data = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: data))
        #expect(hasInk(bitmap, from: 0, to: 25, imageWidth: image.size.width))
        #expect(data != BatteryMenuImage.image(for: battery, showPercentage: false).tiffRepresentation)
        #expect(BatteryMenuImage.symbol(for: charging.stale(message: "Read failed")) == "questionmark.circle")
        let percentageImage = BatteryMenuImage.image(for: charging, showPercentage: true)
        let percentageData = try #require(percentageImage.tiffRepresentation)
        let percentageBitmap = try #require(NSBitmapImageRep(data: percentageData))
        #expect(hasInk(percentageBitmap, from: 29, to: percentageImage.size.width, imageWidth: percentageImage.size.width))
    }

    @Test func chargingFillTracksExactPercentageEvenWhenTextIsHidden() throws {
        var previousInk: CGFloat = -1
        for percent in [0, 20, 70, 100] {
            let image = BatteryMenuImage.image(for: PowerSnapshot(state: .charging, chargePercent: percent), showPercentage: false)
            let data = try #require(image.tiffRepresentation)
            let bitmap = try #require(NSBitmapImageRep(data: data))
            var ink: CGFloat = 0
            for x in 0..<bitmap.pixelsWide {
                for y in 0..<bitmap.pixelsHigh { ink += bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0 }
            }
            #expect(ink > previousInk)
            previousInk = ink
        }
        let twenty = BatteryMenuImage.image(for: PowerSnapshot(state: .charging, chargePercent: 20), showPercentage: false)
        let twentyOne = BatteryMenuImage.image(for: PowerSnapshot(state: .charging, chargePercent: 21), showPercentage: false)
        #expect(twenty.tiffRepresentation != twentyOne.tiffRepresentation)
        #expect(twenty === BatteryMenuImage.image(for: PowerSnapshot(state: .charging, chargePercent: 20), showPercentage: false))
    }

    @Test func percentageIsDrawnInsideNativeImage() throws {
        let snapshot = PowerSnapshot(state: .paused, chargePercent: 80)
        let image = BatteryMenuImage.image(for: snapshot, showPercentage: true)
        #expect(image.size.width > 22)
        let data = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: data))
        #expect(hasInk(bitmap, from: 22, to: image.size.width, imageWidth: image.size.width))
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
