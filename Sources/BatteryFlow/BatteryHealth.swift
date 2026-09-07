import Foundation
import Darwin

struct BatteryHealthSnapshot: Codable, Equatable, Sendable {
    var condition: String?
    var estimate: String?
    var maximumCapacityPercent: Int?
    var cycleCount: Int?
    var conditionUpdatedAt: Date?
    var capacityUpdatedAt: Date?
    var profiledCondition: String?
    var profiledConditionUpdatedAt: Date?
    var errorMessage: String?

    private static func serviceCondition(_ value: String?) -> Bool {
        ["Check Battery", "Permanent Battery Failure", "Service Recommended", "Service Battery",
         "Replace Soon", "Replace Now"].contains(value ?? "")
    }
    var needsService: Bool {
        Self.serviceCondition(condition) || Self.serviceCondition(profiledCondition) || estimate == "Poor"
    }
    var title: String {
        if needsService { return "Service recommended" }
        if let condition = Self.nonempty(condition) { return condition }
        if let condition = Self.nonempty(profiledCondition) {
            return condition == "Good" ? "Normal" : condition
        }
        switch estimate {
        case "Good": return "Normal"
        case "Fair": return "Reduced capacity"
        default: return "Health unavailable"
        }
    }
    var displayedConditionUpdatedAt: Date? {
        if Self.serviceCondition(profiledCondition) { return profiledConditionUpdatedAt }
        if Self.nonempty(condition) != nil || estimate == "Poor" { return conditionUpdatedAt }
        if Self.nonempty(profiledCondition) != nil { return profiledConditionUpdatedAt }
        return conditionUpdatedAt
    }
    var capacityText: String { maximumCapacityPercent.map { "\($0)% maximum capacity" } ?? "Maximum capacity unavailable" }

    static func nonempty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}

struct ProfiledBatteryHealth: Equatable, Sendable {
    var maximumCapacityPercent: Int?
    var condition: String?
    var cycleCount: Int?
}

enum HealthReadError: LocalizedError {
    case failed(String)
    var errorDescription: String? { switch self { case let .failed(message): message } }
}

protocol HealthReading: Sendable {
    func readHealth() async throws -> ProfiledBatteryHealth
}

/// Runs only a fixed system tool in production. The injectable command also tests timeouts.
struct SystemProfilerHealthReader: HealthReading {
    func readHealth() async throws -> ProfiledBatteryHealth {
        let data = try await BoundedCommand.run(
            executable: "/usr/sbin/system_profiler", arguments: ["SPPowerDataType", "-json"], timeout: 10)
        return try Self.parse(from: data)
    }
    static func parse(from data: Data) throws -> ProfiledBatteryHealth {
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let items = root?["SPPowerDataType"] as? [[String: Any]] ?? []
        for item in items where item["_name"] as? String == "spbattery_information" {
            guard let health = item["sppower_battery_health_info"] as? [String: Any] else { continue }
            return ProfiledBatteryHealth(
                maximumCapacityPercent: integer(health["sppower_battery_health_maximum_capacity"], range: 0...100),
                condition: BatteryHealthSnapshot.nonempty(health["sppower_battery_health"] as? String),
                cycleCount: integer(health["sppower_battery_cycle_count"], range: 0...100_000))
        }
        throw HealthReadError.failed("macOS did not provide battery health. Check Battery settings.")
    }
    static func maximumCapacity(from data: Data) throws -> Int {
        guard let capacity = try parse(from: data).maximumCapacityPercent else {
            throw HealthReadError.failed("macOS did not provide maximum capacity. Check Battery settings.")
        }
        return capacity
    }
    private static func integer(_ value: Any?, range: ClosedRange<Int>) -> Int? {
        if let numeric = value as? NSNumber {
            let number = numeric.doubleValue
            guard CFGetTypeID(numeric) != CFBooleanGetTypeID(), number.isFinite,
                  Double(range.lowerBound)...Double(range.upperBound) ~= number,
                  number.rounded() == number else { return nil }
            return Int(number)
        }
        if let string = value as? String,
           let number = Int(string.trimmingCharacters(in: CharacterSet(charactersIn: "% ").union(.whitespacesAndNewlines))),
           range.contains(number) { return number }
        return nil
    }
}

enum BoundedCommand {
    static func run(executable: String, arguments: [String], timeout: TimeInterval) async throws -> Data {
        try await Task.detached(priority: .utility) {
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            defer { try? output.fileHandleForReading.close() }
            try process.run()
            let watchdog = DispatchWorkItem {
                guard process.isRunning else { return }
                process.terminate()
                Thread.sleep(forTimeInterval: min(0.25, timeout / 2))
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
            DispatchQueue.global(qos: .utility).asyncAfter(
                deadline: .now() + max(0.01, timeout - min(0.25, timeout / 2)), execute: watchdog)
            defer { watchdog.cancel() }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw HealthReadError.failed("Battery health refresh failed or exceeded its time limit.")
            }
            return data
        }.value
    }
}

protocol MonitorClock: Sendable {
    var now: Date { get }
    func sleep(seconds: TimeInterval) async throws
}
struct SystemMonitorClock: MonitorClock {
    var now: Date { Date() }
    func sleep(seconds: TimeInterval) async throws {
        try await Task.sleep(for: .seconds(seconds), tolerance: .seconds(min(seconds / 10, 3)))
    }
}
