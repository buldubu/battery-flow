import Foundation
import Testing
@testable import BatteryFlow

@MainActor
final class FakeLoginService: LoginServicing {
    var status: LoginStatus = .notRegistered
    var available = true
    var failure = false
    var registrations = 0
    var unregistrations = 0
    var settingsOpened = 0
    func register() throws {
        registrations += 1
        if failure { throw HealthReadError.failed("Registration failed") }
        status = .enabled
    }
    func unregister() throws {
        unregistrations += 1
        if failure { throw HealthReadError.failed("Unregistration failed") }
        status = .notRegistered
    }
    func openSettings() { settingsOpened += 1 }
}

struct PreferencesHealthTests {
    @Test @MainActor func focusedDefaultsAndRoundTrip() {
        let pref = TestPreferences()
        defer { pref.cleanup() }
        #expect(pref.value.appearance == .system)
        #expect(!pref.value.showPercentage)
        #expect(pref.value.temperatureUnit == .celsius)
        #expect(pref.value.animationsEnabled)
        #expect(pref.value.recordingEnabled)
        #expect(pref.value.retentionDays == 30)
        #expect(pref.value.historyMetric == .power)
        #expect(pref.value.historyRange == .day)
        pref.value.appearance = .dark
        pref.value.showPercentage = true
        pref.value.temperatureUnit = .fahrenheit
        pref.value.animationsEnabled = false
        pref.value.recordingEnabled = false
        pref.value.historyMetric = .temperature
        pref.value.historyRange = .week
        pref.value.setRetentionDays(7)
        let restored = AppPreferences(defaults: pref.defaults)
        #expect(restored.appearance == .dark)
        #expect(restored.showPercentage)
        #expect(restored.temperatureUnit == .fahrenheit)
        #expect(!restored.animationsEnabled)
        #expect(!restored.recordingEnabled)
        #expect(restored.retentionDays == 7)
        #expect(restored.historyRange == .week)
        #expect(restored.historyMetric == .temperature)
    }

    @Test @MainActor func invalidPreferencesAndRangeClamping() {
        let pref = TestPreferences()
        defer { pref.cleanup() }
        pref.defaults.set("invalid", forKey: "appearance")
        pref.defaults.set(-1, forKey: "retentionDays")
        let restored = AppPreferences(defaults: pref.defaults)
        #expect(restored.appearance == .system)
        #expect(restored.retentionDays == 30)
        restored.historyRange = .month
        restored.setRetentionDays(1)
        #expect(restored.historyRange == .day)
        #expect(restored.availableRanges == [.hour, .day])
        restored.setRetentionDays(400)
        #expect(restored.retentionDays == 1)
    }

    @Test func temperatureConversionAndMissingValues() {
        #expect(TemperatureUnit.fahrenheit.convert(0) == 32)
        #expect(TemperatureUnit.fahrenheit.convert(100) == 212)
        #expect(TemperatureUnit.celsius.format(nil) == "—")
        #expect(TemperatureUnit.fahrenheit.format(0) == "32.0 °F")
    }

    @Test @MainActor func loginInitializationNeverRegistersOrRestoresDesiredState() {
        let service = FakeLoginService()
        let controller = LaunchAtLoginController(service: service)
        #expect(!controller.isEnabled)
        #expect(service.registrations == 0)
        service.status = .enabled
        controller.refresh()
        #expect(controller.isEnabled)
        service.status = .requiresApproval
        controller.refresh()
        #expect(!controller.isEnabled)
        #expect(controller.statusMessage != nil)
        #expect(service.registrations == 0)
        controller.openSettings()
        #expect(service.settingsOpened == 1)
    }

    @Test @MainActor func loginErrorsSurviveRefreshUntilSuccess() {
        let service = FakeLoginService()
        let controller = LaunchAtLoginController(service: service)
        service.failure = true
        controller.setEnabled(true)
        #expect(controller.errorMessage == "Registration failed")
        controller.refresh()
        #expect(controller.errorMessage != nil)
        #expect(!controller.isEnabled)
        service.failure = false
        controller.setEnabled(true)
        #expect(controller.errorMessage == nil)
        #expect(controller.isEnabled)
        controller.setEnabled(false)
        #expect(!controller.isEnabled)
        #expect(service.unregistrations == 1)
    }

    @Test func capacityParsingUsesMacOSValue() throws {
        for value: Any in ["%71", "71%", 71] {
            let data = try JSONSerialization.data(withJSONObject: [
                "SPPowerDataType": [["_name": "spbattery_information",
                    "sppower_battery_health_info": ["sppower_battery_health_maximum_capacity": value]]]
            ])
            #expect(try SystemProfilerHealthReader.maximumCapacity(from: data) == 71)
        }
        #expect(throws: (any Error).self) { try SystemProfilerHealthReader.maximumCapacity(from: Data("{}".utf8)) }
        #expect(throws: (any Error).self) { try SystemProfilerHealthReader.maximumCapacity(from: Data("broken".utf8)) }
    }

    @Test func serviceConditionComesFromMacOSNotCycleCount() {
        var health = BatteryHealthSnapshot(estimate: "Good", maximumCapacityPercent: 71, cycleCount: 1226)
        #expect(!health.needsService)
        #expect(health.title == "Normal")
        health.condition = "Check Battery"
        #expect(health.needsService)
        #expect(health.title == "Service recommended")
    }

    @Test func boundedHealthCommandTimesOutAndHandlesExitFailure() async {
        let start = Date()
        await #expect(throws: (any Error).self) {
            try await BoundedCommand.run(executable: "/bin/sleep", arguments: ["3"], timeout: 0.2)
        }
        #expect(Date().timeIntervalSince(start) < 2)
        await #expect(throws: (any Error).self) {
            try await BoundedCommand.run(executable: "/usr/bin/false", arguments: [], timeout: 1)
        }
    }
}
