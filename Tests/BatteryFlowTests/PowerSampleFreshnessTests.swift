import Foundation
import IOKit.ps
import Testing
@testable import BatteryFlow

struct PowerSampleFreshnessTests {
    @Test func unrelatedVoltageCannotReleaseCachedChargingPower() {
        var freshness = PowerSampleFreshness()
        var raw = telemetry()
        raw.isCharging = true
        raw.directAdapterPowerMilliwatts = 20000
        raw.directBatteryPowerMilliwatts = 10000
        raw.powerSampleCounter = 10
        raw.batteryPowerSampleCounter = 10
        raw.systemLoadSampleCounter = 10
        _ = freshness.snapshot(from: raw)
        raw.isCharging = false
        #expect(freshness.snapshot(from: raw).isAwaitingPowerData)
        raw.voltageMillivolts = 12001
        let waiting = freshness.snapshot(from: raw)
        #expect(waiting.isAwaitingPowerData)
        #expect(waiting.state == .paused)
        // A changed direct value also cannot bypass an unchanged channel counter.
        raw.directAdapterPowerMilliwatts = 10000
        raw.directBatteryPowerMilliwatts = 0
        #expect(freshness.snapshot(from: raw).isAwaitingPowerData)
        raw.batteryPowerSampleCounter = 11
        let fresh = freshness.snapshot(from: raw)
        #expect(!fresh.isAwaitingPowerData)
        #expect(fresh.state == .paused)
        #expect(fresh.quality == .valid)
    }

    @Test func counterlessDirectPowerIgnoresUnusedVoltage() {
        var freshness = PowerSampleFreshness()
        var raw = telemetry()
        _ = freshness.snapshot(from: raw)
        freshness.invalidate()
        raw.voltageMillivolts = 12001
        #expect(freshness.snapshot(from: raw).isAwaitingPowerData)
        raw.directAdapterPowerMilliwatts = 11000
        raw.directSystemLoadMilliwatts = 11000
        #expect(!freshness.snapshot(from: raw).isAwaitingPowerData)
    }

    @Test func connectionPresentationExpiresAndDoesNotDelayCharging() {
        var presentation = PowerPresentation()
        var raw = telemetry()
        raw.externalConnected = false
        _ = presentation.present(PowerMath.snapshot(from: raw))
        raw.externalConnected = true
        let connected = presentation.present(PowerMath.snapshot(from: raw))
        #expect(connected.isConnecting)
        #expect(connected.displayTitle == "Power Connected")
        #expect(!connected.canAnimate)
        raw.timestamp = testDate.addingTimeInterval(3)
        let settled = presentation.present(PowerMath.snapshot(from: raw))
        #expect(!settled.isConnecting)
        #expect(settled.displayTitle == "Sailing")
        raw.externalConnected = false
        #expect(!presentation.present(PowerMath.snapshot(from: raw)).isConnecting)
        raw.externalConnected = true
        #expect(presentation.present(PowerMath.snapshot(from: raw)).isConnecting)
        raw.isCharging = true
        let charging = presentation.present(PowerMath.snapshot(from: raw))
        #expect(!charging.isConnecting)
        #expect(charging.state == .charging)
        raw.isCharging = false
        #expect(!presentation.present(PowerMath.snapshot(from: raw)).isConnecting)
    }

    @Test func alreadyConnectedLaunchAndFullBatterySkipConnectionPresentation() {
        var presentation = PowerPresentation()
        var raw = telemetry()
        #expect(!presentation.present(PowerMath.snapshot(from: raw)).isConnecting)
        raw.externalConnected = false
        _ = presentation.present(PowerMath.snapshot(from: raw))
        raw.externalConnected = true
        raw.isFullyCharged = true
        #expect(!presentation.present(PowerMath.snapshot(from: raw)).isConnecting)
    }

    @Test func presentationKeepsStableValuesWithoutTreatingThemAsCurrent() {
        var presentation = PowerPresentation()
        var initial = PowerMath.snapshot(from: telemetry())
        initial.powerUpdatedAt = testDate
        let stable = presentation.present(initial)
        var waiting = initial
        waiting.timestamp = testDate.addingTimeInterval(20)
        waiting.state = .charging
        waiting.isCharging = true
        waiting.adapter = .unavailable
        waiting.battery = .unavailable
        waiting.system = .unavailable
        waiting.quality = .partial
        waiting.isAwaitingPowerData = true
        waiting.powerUpdatedAt = waiting.timestamp
        let displayed = presentation.present(waiting)
        #expect(displayed.state == .charging)
        #expect(displayed.timestamp == waiting.timestamp)
        #expect(displayed.adapter == stable.adapter)
        #expect(displayed.battery == stable.battery)
        #expect(displayed.system == stable.system)
        #expect(displayed.powerUpdatedAt == testDate)
        #expect(displayed.isAwaitingPowerData)
        #expect(!displayed.canAnimate)
        #expect(displayed.errorMessage == nil)
    }

    @Test func presentationResumesSmoothingFromLastStableSample() throws {
        var presentation = PowerPresentation()
        let initial = PowerMath.snapshot(from: telemetry())
        _ = presentation.present(initial)
        var waiting = initial
        waiting.timestamp = testDate.addingTimeInterval(1)
        waiting.isAwaitingPowerData = true
        waiting.quality = .partial
        waiting.adapter = .unavailable
        waiting.battery = .unavailable
        waiting.system = .unavailable
        _ = presentation.present(waiting)
        var nextRaw = telemetry(at: testDate.addingTimeInterval(3))
        nextRaw.directAdapterPowerMilliwatts = 20000
        nextRaw.directSystemLoadMilliwatts = 20000
        let displayed = presentation.present(PowerMath.snapshot(from: nextRaw))
        let adapter = try #require(displayed.adapter.watts)
        #expect(adapter > 10 && adapter < 20)
        #expect(!displayed.isAwaitingPowerData)
    }

    @Test func presentationNeverCarriesBatteryOnlyValuesIntoACState() {
        var presentation = PowerPresentation()
        var battery = PowerMath.snapshot(from: telemetry())
        battery.externalConnected = false
        battery.state = .onBattery
        battery.adapter = PowerReading(0, source: .calculated)
        battery.battery = PowerReading(-10)
        battery.system = PowerReading(10)
        _ = presentation.present(battery)
        var connected = battery
        connected.externalConnected = true
        connected.state = .charging
        connected.isCharging = true
        connected.adapter = .unavailable
        connected.battery = .unavailable
        connected.system = .unavailable
        connected.quality = .partial
        connected.isAwaitingPowerData = true
        connected.powerUpdatedAt = nil
        let displayed = presentation.present(connected)
        #expect(displayed.adapter.watts == nil)
        #expect(displayed.battery.watts == nil)
        #expect(displayed.system.watts == nil)
        #expect(displayed.powerUpdatedAt == nil)
    }

    @Test func cachedHalfWattDoesNotCrossAConnectionChange() {
        var freshness = PowerSampleFreshness()
        var raw = telemetry()
        raw.externalConnected = false
        raw.powerSampleCounter = 100
        raw.directAdapterPowerMilliwatts = 500
        raw.directBatteryPowerMilliwatts = 300
        raw.directSystemLoadMilliwatts = 200
        _ = freshness.snapshot(from: raw)
        raw.externalConnected = true
        raw.isCharging = true
        for second in 0...20 {
            raw.timestamp = testDate.addingTimeInterval(Double(second))
            let snapshot = freshness.snapshot(from: raw)
            #expect(snapshot.state == .charging)
            #expect(snapshot.isAwaitingPowerData)
            #expect(snapshot.adapter.watts == nil)
            #expect(ReadingFormat.watts(snapshot.adapter.watts) == "—")
            #expect(!snapshot.canAnimate)
            #expect(snapshot.chargePercent == 80)
            let point = HistoryPoint(snapshot: snapshot)
            #expect(point.quality == .partial)
            #expect(point.adapterPowerWatts == nil)
        }
        // A genuinely new 0.5 W measurement is allowed; low wattage itself is not an error.
        raw.powerSampleCounter = 101
        let fresh = freshness.snapshot(from: raw)
        #expect(!fresh.isAwaitingPowerData)
        #expect(fresh.quality == .valid)
        #expect(fresh.adapter.watts == 0.5)
    }

    @Test func changedRegistryTimestampAloneDoesNotRefreshPower() {
        var freshness = PowerSampleFreshness()
        let power: [String: Any] = ["SystemPowerInAccumulatorCount": 42,
            "SystemPowerIn": 10000, "BatteryPower": 0, "SystemLoad": 10000]
        var properties: [String: Any] = ["ExternalConnected": true, "IsCharging": false,
            "UpdateTime": 1780000000, "PowerTelemetryData": power]
        _ = freshness.snapshot(from: BatteryTelemetryReader.decode(properties))
        freshness.invalidate()
        properties["UpdateTime"] = 1780000020
        let result = freshness.snapshot(from: BatteryTelemetryReader.decode(properties))
        #expect(result.isAwaitingPowerData)
        #expect(result.adapter.watts == nil)
    }

    @Test func freshZeroAndSailingSurviveCounterReset() {
        var freshness = PowerSampleFreshness()
        var raw = telemetry()
        raw.isCharging = true
        raw.powerSampleCounter = 99
        raw.directAdapterPowerMilliwatts = 20000
        raw.directBatteryPowerMilliwatts = 10000
        _ = freshness.snapshot(from: raw)
        raw.isCharging = false
        let cached = freshness.snapshot(from: raw)
        #expect(cached.isAwaitingPowerData)
        #expect(cached.state == .paused)
        raw.powerSampleCounter = 0
        raw.directAdapterPowerMilliwatts = 10000
        raw.directBatteryPowerMilliwatts = 0
        let fresh = freshness.snapshot(from: raw)
        #expect(!fresh.isAwaitingPowerData)
        #expect(fresh.state == .paused)
        #expect(fresh.battery.watts == 0)
        #expect(fresh.quality == .valid)
    }

    @Test func conflictingRegistrySourceCannotReleaseCachedWattages() {
        var freshness = PowerSampleFreshness()
        var raw = telemetry()
        raw.externalConnected = true
        raw.isCharging = true
        raw.registryExternalConnected = false
        raw.powerSampleCounter = 1
        #expect(freshness.snapshot(from: raw).isAwaitingPowerData)
        raw.powerSampleCounter = 2
        #expect(freshness.snapshot(from: raw).isAwaitingPowerData)
        raw.registryExternalConnected = true
        #expect(freshness.snapshot(from: raw).isAwaitingPowerData)
        raw.powerSampleCounter = 3
        raw.directAdapterPowerMilliwatts = 20000
        raw.directBatteryPowerMilliwatts = 10000
        #expect(freshness.snapshot(from: raw).quality == .valid)
    }

    @Test func missingCounterNeedsChangedMeasurementsAfterWake() {
        var freshness = PowerSampleFreshness()
        var raw = telemetry()
        #expect(freshness.snapshot(from: raw).quality == .valid)
        freshness.invalidate()
        raw.timestamp = testDate.addingTimeInterval(60)
        let waiting = freshness.snapshot(from: raw)
        #expect(waiting.isAwaitingPowerData)
        #expect(ReadingFormat.watts(waiting.stale(message: "Read failed").adapter.watts) == "—")
        raw.directAdapterPowerMilliwatts = 11000
        raw.directSystemLoadMilliwatts = 11000
        #expect(freshness.snapshot(from: raw).quality == .valid)
    }

    @Test func decodesCounterAndRejectsSentinels() {
        for value: NSNumber in [0, 1234] {
            let raw = BatteryTelemetryReader.decode(["PowerTelemetryData": ["SystemPowerInAccumulatorCount": value]])
            #expect(raw.powerSampleCounter == value.int64Value)
        }
        for value: NSNumber in [-1, NSNumber(value: UInt64.max), true, 0.5] {
            let raw = BatteryTelemetryReader.decode(["PowerTelemetryData": ["SystemPowerInAccumulatorCount": value]])
            #expect(raw.powerSampleCounter == nil)
        }
    }

    @Test func batteryOrSystemCounterCanReleaseIdleAdapterSample() {
        var freshness = PowerSampleFreshness()
        var raw = telemetry()
        raw.externalConnected = false
        raw.powerSampleCounter = 50
        raw.batteryPowerSampleCounter = 100
        raw.systemLoadSampleCounter = 200
        raw.directAdapterPowerMilliwatts = 0
        raw.directBatteryPowerMilliwatts = -6000
        raw.directSystemLoadMilliwatts = 6000
        _ = freshness.snapshot(from: raw)

        raw.externalConnected = true
        raw.batteryPowerSampleCounter = 101
        raw.systemLoadSampleCounter = 201
        let current = freshness.snapshot(from: raw)
        #expect(!current.isAwaitingPowerData)
        #expect(current.quality == .valid)
        #expect(current.adapter.watts == 0)
        #expect(current.battery.watts == -6)
        #expect(current.system.watts == 6)
        #expect(current.state == .paused)
    }
}
