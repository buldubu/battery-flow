import Foundation
import IOKit.ps
import Testing
@testable import BatteryFlow

@MainActor
struct PowerTransitionTests {
    @Test func neutralPlugExpiresWhilePanelIsClosed() async {
        let pref = TestPreferences()
        defer { pref.cleanup() }
        let clock = ManualPollingClock()
        let reader = MockTelemetryReader()
        let history = HistoryStore(preferences: pref.value, files: MemoryHistoryFiles(), clock: clock)
        var raw = telemetry()
        raw.externalConnected = false
        raw.directAdapterPowerMilliwatts = 0
        raw.directBatteryPowerMilliwatts = -10000
        await reader.setReading(raw)
        let monitor = PowerMonitor(history: history, reader: reader, healthReader: MockHealthReader(), clock: clock)
        monitor.start(observeSystem: false)
        defer { monitor.stop() }
        await waitFor { clock.intervals == [30] }
        raw.externalConnected = true
        await reader.setReading(raw)
        monitor.powerChanged()
        await waitFor { clock.intervals == [0.5, 30] }
        clock.advance(0.5)
        await waitFor { monitor.snapshot.isConnecting && clock.intervals == [1] }
        #expect(BatteryMenuImage.symbol(for: monitor.snapshot) == "powerplug.fill")
        clock.advance(3)
        await waitFor { monitor.snapshot.timestamp == clock.now && clock.intervals == [1] }
        #expect(!monitor.snapshot.isConnecting)
        #expect(BatteryMenuImage.symbol(for: monitor.snapshot) == "sailboat.fill")
    }

    @Test func cachedPowerIsExcludedFromHistoryWhileChargingIconUpdates() async {
        let pref = TestPreferences()
        defer { pref.cleanup() }
        let clock = MutableClock()
        let history = HistoryStore(preferences: pref.value, files: MemoryHistoryFiles(), clock: clock)
        let reader = MockTelemetryReader()
        let monitor = PowerMonitor(history: history, reader: reader, healthReader: MockHealthReader(), clock: clock)
        var raw = telemetry()
        raw.externalConnected = false
        raw.powerSampleCounter = 100
        raw.directAdapterPowerMilliwatts = 0
        raw.directBatteryPowerMilliwatts = -10000
        await reader.setReading(raw)
        await monitor.refresh()
        raw.externalConnected = true
        raw.isCharging = true
        await reader.setReading(raw)
        clock.advance(61)
        await monitor.refresh()
        #expect(monitor.snapshot.state == .charging)
        #expect(monitor.snapshot.isAwaitingPowerData)
        #expect(history.points.count == 2)
        #expect(history.points.last?.quality == .partial)
        #expect(history.points.last?.adapterPowerWatts == nil)
        let pendingIcon = BatteryMenuImage.image(for: monitor.snapshot, showPercentage: false)
        raw.powerSampleCounter = 101
        raw.directAdapterPowerMilliwatts = 29000
        raw.directBatteryPowerMilliwatts = 19000
        await reader.setReading(raw)
        clock.advance(1)
        await monitor.refresh()
        #expect(monitor.snapshot.adapter.watts == 29)
        #expect(monitor.snapshot.quality == .valid)
        // Waiting for watts must not remove or change the charging icon.
        #expect(pendingIcon.tiffRepresentation == BatteryMenuImage.image(for: monitor.snapshot, showPercentage: false).tiffRepresentation)
    }

    private func waitFor(line: Int = #line, _ condition: () -> Bool) async {
        for _ in 0..<10_000 {
            if condition() { return }
            await Task.yield()
        }
        Issue.record("Polling schedule did not reach the expected state at line \(line)")
    }

    @Test func earlyPlugNotificationRetriesWithoutOpeningPanel() async {
        let pref = TestPreferences()
        defer { pref.cleanup() }
        let clock = ManualPollingClock()
        let history = HistoryStore(preferences: pref.value, files: MemoryHistoryFiles(), clock: clock)
        let reader = MockTelemetryReader()
        var raw = telemetry()
        raw.externalConnected = false
        raw.directAdapterPowerMilliwatts = 0
        raw.directBatteryPowerMilliwatts = -10000
        await reader.setReading(raw)
        let monitor = PowerMonitor(history: history, reader: reader, healthReader: MockHealthReader(), clock: clock)
        monitor.start(observeSystem: false)
        defer { monitor.stop() }
        await waitFor { clock.intervals == [30] }
        monitor.powerChanged()
        monitor.powerChanged()
        await waitFor { clock.intervals == [0.5, 30] }
        clock.advance(0.5)
        await waitFor { clock.intervals == [1] }
        // The first notification/read precedes the updated connection properties.
        #expect(monitor.snapshot.state == .onBattery)
        raw.externalConnected = true
        raw.isCharging = true
        await reader.setReading(raw)
        clock.advance(1)
        await waitFor { monitor.snapshot.externalConnected == true && clock.intervals == [1] }
        #expect(monitor.snapshot.state == .charging)
        #expect(monitor.snapshot.isAwaitingPowerData)
        #expect(monitor.snapshot.adapter.watts == nil)
        #expect(monitor.snapshot.battery.watts == nil)
        raw.directAdapterPowerMilliwatts = 20000
        raw.directBatteryPowerMilliwatts = 10000
        await reader.setReading(raw)
        clock.advance(1)
        await waitFor { monitor.snapshot.quality == .valid && clock.intervals == [1] }
        #expect(monitor.snapshot.adapter.watts == 20)
        #expect(history.points.count == 1)
        #expect(await reader.maximumInFlight == 1)
        clock.advance(44)
        await waitFor { clock.intervals == [30] }
    }

    @Test func driverMayKeepZeroInputForThirtySecondsAfterPluggingIn() async {
        let pref = TestPreferences()
        defer { pref.cleanup() }
        let clock = ManualPollingClock()
        let reader = MockTelemetryReader()
        let history = HistoryStore(preferences: pref.value, files: MemoryHistoryFiles(), clock: clock)
        var raw = telemetry()
        raw.externalConnected = false
        raw.directAdapterPowerMilliwatts = 0
        raw.directBatteryPowerMilliwatts = -10000
        await reader.setReading(raw)
        let monitor = PowerMonitor(history: history, reader: reader, healthReader: MockHealthReader(), clock: clock)
        monitor.start(observeSystem: false)
        defer { monitor.stop() }
        await waitFor { clock.intervals == [30] }
        monitor.powerChanged()
        await waitFor { clock.intervals == [0.5, 30] }
        raw.externalConnected = true
        await reader.setReading(raw)
        clock.advance(0.5)
        await waitFor { monitor.snapshot.externalConnected == true && clock.intervals == [1] }
        clock.advance(32)
        await waitFor { monitor.snapshot.timestamp == clock.now && clock.intervals == [1] }
        #expect(monitor.snapshot.isAwaitingPowerData)
        #expect(monitor.snapshot.adapter.watts == nil)
        #expect(monitor.snapshot.battery.watts == nil)
        raw.isCharging = true
        raw.directAdapterPowerMilliwatts = 20000
        raw.directBatteryPowerMilliwatts = 10000
        await reader.setReading(raw)
        clock.advance(1)
        await waitFor { monitor.snapshot.state == .charging && clock.intervals == [1] }
        #expect(monitor.snapshot.adapter.watts == 20)
        #expect(history.points.count == 1)
        // Charging began well after connection, so its own retry window remains active.
        clock.advance(45)
        await waitFor { clock.intervals == [30] }
    }

    @Test func ordinaryBatteryUpdateDoesNotStartFastPolling() async {
        let pref = TestPreferences()
        defer { pref.cleanup() }
        let clock = ManualPollingClock()
        let history = HistoryStore(preferences: pref.value, files: MemoryHistoryFiles(), clock: clock)
        let monitor = PowerMonitor(history: history, reader: MockTelemetryReader(), healthReader: MockHealthReader(), clock: clock)
        monitor.start(observeSystem: false)
        defer { monitor.stop() }
        await waitFor { clock.intervals == [2] }
        monitor.powerInformationChanged()
        await waitFor { clock.intervals == [0.5, 2] }
        clock.advance(0.5)
        await waitFor { monitor.snapshot.timestamp == clock.now && clock.intervals == [2] }
        // A source-change event in the same debounce window must still request fast polling.
        monitor.powerInformationChanged()
        monitor.powerChanged()
        await waitFor { clock.intervals == [0.5, 2] }
        clock.advance(0.5)
        await waitFor { monitor.snapshot.timestamp == clock.now && clock.intervals == [1] }
    }

    @Test func chargingLimitChangeStartsFastPollingWithoutCableChange() async {
        let pref = TestPreferences()
        defer { pref.cleanup() }
        let clock = ManualPollingClock()
        let history = HistoryStore(preferences: pref.value, files: MemoryHistoryFiles(), clock: clock)
        let reader = MockTelemetryReader()
        var raw = telemetry()
        raw.externalConnected = true
        raw.isCharging = false
        raw.powerSampleCounter = 40
        await reader.setReading(raw)
        let monitor = PowerMonitor(history: history, reader: reader, healthReader: MockHealthReader(), clock: clock)
        monitor.start(observeSystem: false)
        defer { monitor.stop() }
        await waitFor { clock.intervals == [2] }

        // Raising a charge limit changes charging status but leaves AC connected.
        raw.isCharging = true
        await reader.setReading(raw)
        monitor.powerInformationChanged()
        await waitFor { clock.intervals == [0.5, 2] }
        clock.advance(0.5)
        await waitFor { monitor.snapshot.state == .charging && clock.intervals == [1] }
        #expect(monitor.snapshot.externalConnected == true)
        #expect(monitor.snapshot.isAwaitingPowerData)
        #expect(monitor.snapshot.adapter.watts == 10)

        raw.powerSampleCounter = 41
        raw.directAdapterPowerMilliwatts = 20000
        raw.directBatteryPowerMilliwatts = 10000
        await reader.setReading(raw)
        clock.advance(1)
        await waitFor { monitor.snapshot.quality == .valid && clock.intervals == [1] }
        #expect(monitor.snapshot.adapter.watts == 20)
        #expect(!monitor.snapshot.isAwaitingPowerData)
    }

    @Test func immediatePowerNotificationsAreDeliveredAndRemovedOnStop() async {
        // Use the process-local center; never post synthetic power notifications to macOS.
        let center = CFNotificationCenterGetLocalCenter()!
        var changes = 0
        let events = PowerEvents(onPowerChange: { changes += 1 }, onBatteryUpdate: {},
            onModeChange: {}, onSleep: {}, onWake: {}, powerNotificationCenter: center)
        let name = CFNotificationName(kIOPSNotifyPowerSource as CFString)
        CFNotificationCenterPostNotification(center, name, nil, nil, true)
        await waitFor { changes == 1 }
        let chargingName = CFNotificationName(PowerEvents.chargingIconographyNotification as CFString)
        CFNotificationCenterPostNotification(center, chargingName, nil, nil, true)
        await waitFor { changes == 2 }
        events.stop()
        CFNotificationCenterPostNotification(center, name, nil, nil, true)
        CFNotificationCenterPostNotification(center, chargingName, nil, nil, true)
        for _ in 0..<100 { await Task.yield() }
        #expect(changes == 2)
    }

    @Test func lowPowerBurstIsBoundedAndSleepCancelsIt() async {
        let pref = TestPreferences()
        defer { pref.cleanup() }
        let clock = ManualPollingClock()
        let history = HistoryStore(preferences: pref.value, files: MemoryHistoryFiles(), clock: clock)
        let monitor = PowerMonitor(history: history, reader: MockTelemetryReader(), healthReader: MockHealthReader(), clock: clock)
        monitor.setLowPowerMode(true)
        monitor.start(observeSystem: false)
        defer { monitor.stop() }
        await waitFor { clock.intervals == [4] }
        monitor.powerChanged()
        await waitFor { clock.intervals == [0.5, 4] }
        clock.advance(0.5)
        await waitFor { monitor.snapshot.timestamp == clock.now && clock.intervals == [2] }
        clock.advance(10)
        await waitFor { monitor.snapshot.timestamp == clock.now && clock.intervals == [2] }
        monitor.powerChanged()
        await waitFor { clock.intervals == [0.5, 2] }
        clock.advance(0.5)
        await waitFor { monitor.snapshot.timestamp == clock.now && clock.intervals == [2] }
        clock.advance(35)
        await waitFor { clock.intervals == [4] }
        monitor.setSleeping(true)
        await waitFor { clock.intervals.isEmpty }
        monitor.setSleeping(false)
        await waitFor { clock.intervals == [2] }
        monitor.stop()
        await waitFor { clock.intervals.isEmpty }
    }
}
