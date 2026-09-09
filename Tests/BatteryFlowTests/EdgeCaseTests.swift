import Foundation
import Testing
@testable import BatteryFlow

struct EdgeCaseTests {
    @Test func missingMeasurementCannotHideImpossiblePowerPair() {
        var raw = telemetry()
        raw.directAdapterPowerMilliwatts = 0
        raw.directBatteryPowerMilliwatts = 2000
        raw.directSystemLoadMilliwatts = nil
        #expect(PowerMath.snapshot(from: raw).quality == .inconsistent)
        raw.directAdapterPowerMilliwatts = nil
        raw.systemVoltageInMillivolts = nil
        raw.systemCurrentInMilliamps = nil
        raw.directBatteryPowerMilliwatts = -2000
        raw.directSystemLoadMilliwatts = 0
        let snapshot = PowerMath.snapshot(from: raw)
        #expect(snapshot.quality == .inconsistent)
        #expect(!snapshot.canAnimate)
    }

    @Test func missingPowerAndIdleZeroDoNotAnimate() {
        var raw = RawPowerTelemetry()
        raw.externalConnected = true
        raw.isCharging = false
        #expect(!PowerMath.snapshot(from: raw).canAnimate)
        raw.directAdapterPowerMilliwatts = 0
        raw.directBatteryPowerMilliwatts = 0
        raw.directSystemLoadMilliwatts = 0
        let idle = PowerMath.snapshot(from: raw)
        #expect(idle.quality == .valid)
        #expect(!idle.canAnimate)
    }

    @Test func pendingMemoryRespectsRetentionDuringPersistentReadFailure() async {
        let files = MemoryHistoryFiles()
        files.failReads(true)
        let store = persistence(files)
        _ = await store.synchronize(now: testDate, retentionDays: 1, point: historyPoint())
        _ = await store.synchronize(now: testDate.addingTimeInterval(86400 - 30), retentionDays: 1)
        let expired = await store.synchronize(now: testDate.addingTimeInterval(86400 + 30), retentionDays: 1)
        #expect(expired.points.isEmpty)
        #expect(expired.pendingCount == 0)
        #expect(expired.error != nil)
    }

    @Test func macOSChargingStatusTakesPrecedenceOverDelayedIdlePower() {
        var raw = telemetry()
        raw.isCharging = true
        #expect(PowerMath.snapshot(from: raw).state == .charging)
        #expect(PowerMath.snapshot(from: raw).adapter.watts == nil)
        #expect(PowerMath.snapshot(from: raw).quality == .inconsistent)
        raw.isFullyCharged = true
        #expect(PowerMath.snapshot(from: raw).state == .charging)
        raw.isCharging = false
        #expect(PowerMath.snapshot(from: raw).state == .charged)
    }

    @Test @MainActor func historyKeepsRawObservationsWhileDisplayIsSmoothed() async {
        let pref = TestPreferences()
        defer { pref.cleanup() }
        let clock = MutableClock()
        let history = HistoryStore(preferences: pref.value, files: MemoryHistoryFiles(), clock: clock)
        let reader = MockTelemetryReader()
        let monitor = PowerMonitor(history: history, reader: reader, healthReader: MockHealthReader(), clock: clock)
        await monitor.refresh()
        clock.advance(59)
        await monitor.refresh()
        var raw = telemetry()
        raw.directAdapterPowerMilliwatts = 20000
        raw.directSystemLoadMilliwatts = 20000
        await reader.setReading(raw)
        clock.advance(1)
        await monitor.refresh()
        #expect(history.points.count == 2)
        #expect(history.points.last?.adapterPowerWatts == 20)
        #expect((monitor.snapshot.adapter.watts ?? 0) > 12)
        #expect((monitor.snapshot.adapter.watts ?? 0) < 13)
    }

    @Test @MainActor func recordingResumesWithoutFillingPausedPeriod() async {
        let pref = TestPreferences()
        defer { pref.cleanup() }
        let clock = MutableClock()
        let history = HistoryStore(preferences: pref.value, files: MemoryHistoryFiles(), clock: clock)
        await history.record(PowerMath.snapshot(from: telemetry(at: clock.now)))
        pref.value.recordingEnabled = false
        clock.advance(600)
        await history.record(PowerMath.snapshot(from: telemetry(at: clock.now)))
        #expect(history.points.count == 1)
        pref.value.recordingEnabled = true
        clock.advance(60)
        await history.record(PowerMath.snapshot(from: telemetry(at: clock.now)))
        #expect(history.points.count == 2)
        #expect(Set(history.chartSamples(in: .day).map(\.segment)).count == 2)
    }

    @Test func unsignedSentinelsAndFractionsNeverBecomePlausibleReadings() {
        let raw = BatteryTelemetryReader.decode([
            "CurrentCapacity": NSNumber(value: UInt64.max),
            "Amperage": NSNumber(value: UInt64.max),
            "Voltage": NSNumber(value: 12000.25),
            "PowerTelemetryData": ["BatteryPower": NSNumber(value: UInt64.max),
                                   "SystemLoad": NSNumber(value: true)]
        ])
        #expect(raw.chargePercent == nil)
        #expect(raw.amperageMilliamps == nil)
        #expect(raw.voltageMillivolts == nil)
        #expect(raw.directBatteryPowerMilliwatts == nil)
        #expect(raw.directSystemLoadMilliwatts == nil)
        var extreme = telemetry()
        extreme.rawCurrentCapacity = .max
        extreme.rawMaxCapacity = .max
        #expect(PowerMath.snapshot(from: extreme).hardwarePercent == nil)
    }

    @Test func impossibleDisconnectedInputIsFlagged() {
        var raw = telemetry()
        raw.externalConnected = false
        raw.directBatteryPowerMilliwatts = -10000
        #expect(PowerMath.snapshot(from: raw).quality == .inconsistent)
        raw.directAdapterPowerMilliwatts = nil
        raw.systemVoltageInMillivolts = nil
        raw.systemCurrentInMilliamps = nil
        let calculated = PowerMath.snapshot(from: raw)
        #expect(calculated.adapter.watts == 0)
        #expect(calculated.adapter.source == .calculated)
        #expect(calculated.quality == .valid)
    }

    @Test func zeroInputDoesNotClaimAdapterIsSupplyingPower() {
        var raw = telemetry()
        raw.directAdapterPowerMilliwatts = 0
        raw.directBatteryPowerMilliwatts = -10000
        let snapshot = PowerMath.snapshot(from: raw)
        #expect(snapshot.state == .paused)
        #expect(snapshot.quality == .valid)
        raw.directAdapterPowerMilliwatts = nil
        raw.systemVoltageInMillivolts = 0
        raw.systemCurrentInMilliamps = 0
        #expect(PowerMath.snapshot(from: raw).adapter.watts == 0)
    }

    @Test func detailedOSWarningSurvivesTransientGoodEstimate() {
        let health = BatteryHealthSnapshot(condition: "", estimate: "Good", conditionUpdatedAt: testDate,
            profiledCondition: "Check Battery", profiledConditionUpdatedAt: testDate.addingTimeInterval(-120))
        #expect(health.needsService)
        #expect(health.title == "Service recommended")
        #expect(health.displayedConditionUpdatedAt == testDate.addingTimeInterval(-120))
    }

    @Test func missingCapacityStillPreservesReportedCondition() throws {
        let data = Data(#"{"SPPowerDataType":[{"_name":"spbattery_information","sppower_battery_health_info":{"sppower_battery_health":"Check Battery","sppower_battery_cycle_count":1227}}]}"#.utf8)
        let health = try SystemProfilerHealthReader.parse(from: data)
        #expect(health.maximumCapacityPercent == nil)
        #expect(health.condition == "Check Battery")
        #expect(health.cycleCount == 1227)
        #expect(throws: (any Error).self) { try SystemProfilerHealthReader.maximumCapacity(from: data) }
    }

    @Test @MainActor func datedHealthCacheSurvivesLaunchAndReadFailure() async {
        let pref = TestPreferences()
        defer { pref.cleanup() }
        pref.value.cachedHealth = BatteryHealthSnapshot(maximumCapacityPercent: 71, capacityUpdatedAt: testDate,
            profiledCondition: "Check Battery", profiledConditionUpdatedAt: testDate)
        let restored = AppPreferences(defaults: pref.defaults)
        let reader = MockHealthReader()
        await reader.fail()
        let monitor = PowerMonitor(history: HistoryStore(preferences: restored, files: MemoryHistoryFiles(), clock: FixedClock()),
            reader: MockTelemetryReader(), healthReader: reader, clock: FixedClock(), preferences: restored)
        monitor.refreshHealth()
        await awaitHealth(monitor)
        #expect(monitor.health.maximumCapacityPercent == 71)
        #expect(monitor.health.capacityUpdatedAt == testDate)
        #expect(monitor.health.needsService)
        #expect(monitor.health.errorMessage != nil)
    }

    @Test func partiallyWrittenFirstRecordCanRecoverFromPendingMemory() async {
        let files = MemoryHistoryFiles()
        let store = persistence(files)
        files.failNextAppend(afterBytes: 40)
        let point = historyPoint()
        let failed = await store.synchronize(now: testDate, retentionDays: 30, point: point)
        #expect(failed.pendingCount == 1)
        let original = files.data
        let recovered = await store.synchronize(now: testDate, retentionDays: 30)
        #expect(recovered.error == nil)
        #expect(recovered.points.map(\.id) == [point.id])
        #expect(recovered.pendingCount == 0)
        #expect(files.backups.first == original)
        #expect(files.data?.split(separator: 0x0A).count == 1)
    }
}
