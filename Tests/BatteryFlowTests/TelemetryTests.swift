import Foundation
import Testing
@testable import BatteryFlow

struct TelemetryTests {
    @Test func supportedStatesAndSignAgreement() {
        var raw = telemetry()
        #expect(PowerMath.snapshot(from: raw).state == .paused)
        raw.isFullyCharged = true
        #expect(PowerMath.snapshot(from: raw).state == .charged)
        raw.isFullyCharged = false
        raw.isCharging = true
        raw.directBatteryPowerMilliwatts = 2000
        raw.directAdapterPowerMilliwatts = 12000
        #expect(PowerMath.snapshot(from: raw).state == .charging)
        // A lagging charging flag must never contradict measured battery discharge.
        raw.directBatteryPowerMilliwatts = -2000
        raw.directAdapterPowerMilliwatts = 8000
        #expect(PowerMath.snapshot(from: raw).state == .supplementing)
        raw.externalConnected = false
        raw.directBatteryPowerMilliwatts = -10000
        #expect(PowerMath.snapshot(from: raw).state == .onBattery)
        raw.externalConnected = nil
        #expect(PowerMath.snapshot(from: raw).state == .unavailable)
    }

    @Test func validZeroWinsOverConflictingFallback() {
        var raw = telemetry()
        raw.amperageMilliamps = 1000
        let value = PowerMath.snapshot(from: raw)
        #expect(value.battery.watts == 0)
        #expect(value.battery.source == .reported)
        #expect(value.state == .paused)
        #expect(value.quality == .valid)
    }

    @Test func ratingNeverBecomesMeasuredInput() {
        var raw = telemetry()
        raw.directAdapterPowerMilliwatts = nil
        raw.systemVoltageInMillivolts = nil
        raw.systemCurrentInMilliamps = nil
        raw.directBatteryPowerMilliwatts = -6400
        raw.directSystemLoadMilliwatts = 6400
        let value = PowerMath.snapshot(from: raw)
        #expect(value.adapterRatingWatts == 75)
        #expect(value.adapter.watts == 0)
        #expect(value.adapter.source == .calculated)
        #expect(value.quality == .valid)
    }

    @Test func missingFieldsStayUnavailable() {
        let raw = BatteryTelemetryReader.decode([:])
        #expect(raw.chargePercent == nil)
        #expect(raw.externalConnected == nil)
        #expect(raw.directBatteryPowerMilliwatts == nil)
        let value = PowerMath.snapshot(from: raw)
        #expect(value.chargePercent == nil)
        #expect(value.adapter.watts == nil)
        #expect(value.battery.watts == nil)
        #expect(value.system.watts == nil)
        #expect(value.state == .unavailable)
    }

    @Test func sentinelAndExtremeValuesDoNotOverflowOrClamp() {
        var raw = RawPowerTelemetry()
        raw.externalConnected = true
        raw.isCharging = false
        raw.directBatteryPowerMilliwatts = .min
        raw.directAdapterPowerMilliwatts = .max
        raw.directSystemLoadMilliwatts = -1
        raw.voltageMillivolts = .max
        raw.amperageMilliamps = .min
        raw.chargePercent = 200
        raw.rawTemperature = .max
        let value = PowerMath.snapshot(from: raw)
        #expect(value.battery.watts == nil)
        #expect(value.adapter.watts == nil)
        #expect(value.system.watts == nil)
        #expect(value.chargePercent == nil)
        #expect(value.temperatureCelsius == nil)
        #expect(!PowerMath.consistent(adapter: .nan, battery: 0, system: 0, externalConnected: true))
    }

    @Test func inconsistentPowerIsSuppressedButOtherMetricsSurvive() {
        var raw = telemetry()
        raw.directAdapterPowerMilliwatts = 75000
        let value = PowerMath.snapshot(from: raw)
        #expect(value.quality == .inconsistent)
        #expect(value.adapter.watts == nil)
        #expect(value.battery.watts == nil)
        #expect(value.system.watts == nil)
        #expect(value.chargePercent == 80)
        #expect(value.cycleCount == 1226)
        #expect(value.temperatureCelsius != nil)
        #expect(!value.canAnimate)
        #expect(value.errorMessage != nil)
    }

    @Test func disconnectedChargingPowerIsRejected() {
        var raw = telemetry()
        raw.externalConnected = false
        raw.directBatteryPowerMilliwatts = 1000
        let value = PowerMath.snapshot(from: raw)
        #expect(value.quality == .inconsistent)
        #expect(value.battery.watts == nil)
    }

    @Test func derivedReadingsRequireRealMeasurements() {
        var raw = telemetry()
        raw.directSystemLoadMilliwatts = nil
        let value = PowerMath.snapshot(from: raw)
        #expect(value.system.watts == 10)
        #expect(value.system.source == .calculated)
        raw.directAdapterPowerMilliwatts = nil
        raw.systemVoltageInMillivolts = nil
        raw.systemCurrentInMilliamps = nil
        let partial = PowerMath.snapshot(from: raw)
        #expect(partial.adapter.watts == nil)
        #expect(partial.system.watts == nil)
        #expect(partial.quality == .partial)
    }

    @Test func smoothingUsesElapsedTimeAndPreservesBalance() throws {
        let old = PowerMath.snapshot(from: telemetry())
        var raw = telemetry(at: testDate.addingTimeInterval(3))
        raw.directAdapterPowerMilliwatts = 20000
        raw.directSystemLoadMilliwatts = 20000
        let next = PowerMath.snapshot(from: raw)
        let smoothed = PowerMath.smooth(next, previous: old)
        let watts = try #require(smoothed.adapter.watts)
        #expect(abs(watts - (20 - 10 * exp(-1))) < 0.00001)
        #expect(PowerMath.consistent(adapter: smoothed.adapter.watts, battery: smoothed.battery.watts,
                                    system: smoothed.system.watts, externalConnected: true))
        raw.timestamp = testDate.addingTimeInterval(30)
        #expect(try #require(PowerMath.smooth(PowerMath.snapshot(from: raw), previous: old).adapter.watts) > 19.99)
    }

    @Test func smoothingResetsOnDirectionConnectionAndWake() {
        var raw = telemetry()
        raw.directAdapterPowerMilliwatts = 5000
        raw.directBatteryPowerMilliwatts = -5000
        let old = PowerMath.snapshot(from: raw)
        raw.timestamp = testDate.addingTimeInterval(1)
        raw.directAdapterPowerMilliwatts = 12000
        raw.directBatteryPowerMilliwatts = 2000
        raw.isCharging = true
        let next = PowerMath.snapshot(from: raw)
        #expect(PowerMath.smooth(next, previous: old) == next)
        #expect(PowerMath.smooth(next, previous: old.stale(message: "Sleep")) == next)
        raw.externalConnected = false
        raw.directBatteryPowerMilliwatts = -10000
        let disconnected = PowerMath.snapshot(from: raw)
        #expect(PowerMath.smooth(disconnected, previous: next) == disconnected)
    }

    @Test func staleReadingsRetainTimestampButHidePower() {
        let last = PowerMath.snapshot(from: telemetry())
        let value = last.stale(message: "Read failed")
        #expect(value.timestamp == testDate)
        #expect(value.chargePercent == 80)
        #expect(value.isStale)
        #expect(value.battery.watts == nil)
        #expect(!value.canAnimate)
        #expect(value.state == .unavailable)
    }

    @Test func newRecordStoresQualityAndZero() throws {
        let value = historyPoint()
        let data = try encodeHistory([value])
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["schemaVersion"] as? Int == 2)
        #expect(object["quality"] as? String == "valid")
        #expect(object["batteryPowerWatts"] as? Double == 0)
        #expect(object["batterySource"] as? String == "reported")
    }
}
