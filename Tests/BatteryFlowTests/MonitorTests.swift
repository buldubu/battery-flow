import Foundation
import Testing
@testable import BatteryFlow

actor MockTelemetryReader: TelemetryReading {
    var shouldFail = false
    var inFlight = 0
    var maximumInFlight = 0
    var reads = 0
    var delay: TimeInterval = 0
    var value = telemetry()
    func setReading(_ reading: RawPowerTelemetry) { value = reading }
    func fail() { shouldFail = true }
    func setDelay(_ value: TimeInterval) { delay = value }
    func read() async throws -> RawPowerTelemetry {
        inFlight += 1
        maximumInFlight = max(maximumInFlight, inFlight)
        reads += 1
        defer { inFlight -= 1 }
        if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
        if shouldFail { throw HealthReadError.failed("Telemetry failed") }
        return value
    }
}

actor MockHealthReader: HealthReading {
    var shouldFail = false
    var reads = 0
    func fail() { shouldFail = true }
    func readHealth() throws -> ProfiledBatteryHealth {
        reads += 1
        if shouldFail { throw HealthReadError.failed("Health failed") }
        return ProfiledBatteryHealth(maximumCapacityPercent: 71, condition: "Check Battery", cycleCount: 1226)
    }
}

@MainActor
func awaitHealth(_ monitor: PowerMonitor) async {
    for _ in 0..<1000 {
        if !monitor.isRefreshingHealth { return }
        await Task.yield()
    }
    Issue.record("Health refresh did not complete")
}

struct MonitorTests {
    @Test @MainActor func pollingIntervals() {
        #expect(PowerMonitor.interval(panelVisible: true, lowPowerMode: false) == 1)
        #expect(PowerMonitor.interval(panelVisible: false, lowPowerMode: false) == 30)
        #expect(PowerMonitor.interval(panelVisible: true, lowPowerMode: true) == 2)
        #expect(PowerMonitor.interval(panelVisible: false, lowPowerMode: true) == 60)
    }

    @Test @MainActor func telemetryFailureKeepsLastSuccessfulTimestamp() async {
        let pref = TestPreferences()
        defer { pref.cleanup() }
        let history = HistoryStore(preferences: pref.value, files: MemoryHistoryFiles(), clock: FixedClock())
        let reader = MockTelemetryReader()
        let monitor = PowerMonitor(history: history, reader: reader, healthReader: MockHealthReader(), clock: FixedClock())
        await monitor.refresh()
        #expect(monitor.snapshot.timestamp == testDate)
        #expect(history.points.count == 1)
        await reader.fail()
        await monitor.refresh()
        #expect(monitor.snapshot.timestamp == testDate)
        #expect(monitor.snapshot.isStale)
        #expect(monitor.snapshot.adapter.watts == nil)
        #expect(history.points.count == 1)
        #expect(monitor.health.needsService)
    }

    @Test @MainActor func healthRefreshIsCachedAndFailureRetainsDatedCapacity() async {
        let pref = TestPreferences()
        defer { pref.cleanup() }
        let healthReader = MockHealthReader()
        let history = HistoryStore(preferences: pref.value, files: MemoryHistoryFiles(), clock: FixedClock())
        let monitor = PowerMonitor(history: history, reader: MockTelemetryReader(), healthReader: healthReader, clock: FixedClock())
        monitor.refreshHealth()
        await awaitHealth(monitor)
        #expect(monitor.health.maximumCapacityPercent == 71)
        #expect(monitor.health.capacityUpdatedAt == testDate)
        monitor.refreshHealth()
        #expect(await healthReader.reads == 1)
        await healthReader.fail()
        monitor.refreshHealth(force: true)
        await awaitHealth(monitor)
        #expect(monitor.health.maximumCapacityPercent == 71)
        #expect(monitor.health.capacityUpdatedAt == testDate)
        #expect(monitor.health.errorMessage == "Health failed")
        #expect(await healthReader.reads == 2)
    }

    @Test @MainActor func refreshRequestsNeverOverlap() async {
        let pref = TestPreferences()
        defer { pref.cleanup() }
        let history = HistoryStore(preferences: pref.value, files: MemoryHistoryFiles(), clock: FixedClock())
        let reader = MockTelemetryReader()
        await reader.setDelay(0.02)
        let monitor = PowerMonitor(history: history, reader: reader, healthReader: MockHealthReader(), clock: FixedClock())
        async let first: Void = monitor.refresh()
        async let second: Void = monitor.refresh()
        async let third: Void = monitor.refresh()
        _ = await (first, second, third)
        #expect(await reader.maximumInFlight == 1)
        #expect(history.points.count == 1)
    }

    @Test @MainActor func sleepStopsReadsAndWakeResetsStaleState() async {
        let pref = TestPreferences()
        defer { pref.cleanup() }
        let history = HistoryStore(preferences: pref.value, files: MemoryHistoryFiles(), clock: FixedClock())
        let reader = MockTelemetryReader()
        let monitor = PowerMonitor(history: history, reader: reader, healthReader: MockHealthReader(), clock: FixedClock())
        await monitor.refresh()
        monitor.setSleeping(true)
        await monitor.refresh()
        #expect(await reader.reads == 1)
        #expect(monitor.snapshot.isStale)
        monitor.setSleeping(false)
        await monitor.refresh()
        #expect(await reader.reads == 2)
        #expect(!monitor.snapshot.isStale)
    }
}

struct LiveIntegrationTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BATTERYFLOW_LIVE_TEST"] == "1"))
    func currentMacTelemetryAndHealth() async throws {
        let raw = try await BatteryTelemetryReader().read()
        let snapshot = PowerMath.snapshot(from: raw)
        #expect(snapshot.chargePercent != nil)
        #expect(snapshot.state != .unavailable)
        #expect(snapshot.quality != .inconsistent)
        let report = try await SystemProfilerHealthReader().readHealth()
        print("LIVE: charge=\(snapshot.chargeText), state=\(snapshot.state.title), quality=\(snapshot.quality), health=\(report.condition ?? raw.healthEstimate ?? "Unavailable"), maximumCapacity=\(report.maximumCapacityPercent.map(String.init) ?? "Unavailable")%")
    }
}
