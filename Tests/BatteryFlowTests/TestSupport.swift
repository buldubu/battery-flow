import Foundation
import Testing
@testable import BatteryFlow

let testDate = Date(timeIntervalSince1970: 1_780_000_000)

func telemetry(at date: Date = testDate) -> RawPowerTelemetry {
    RawPowerTelemetry(timestamp: date, chargePercent: 80, rawCurrentCapacity: 2400, rawMaxCapacity: 3000,
        rawTemperature: 3032, cycleCount: 1226, externalConnected: true, isCharging: false, isFullyCharged: false,
        voltageMillivolts: 12000, amperageMilliamps: 0, adapterRatingWatts: 75,
        systemVoltageInMillivolts: 20000, systemCurrentInMilliamps: 500,
        directAdapterPowerMilliwatts: 10000, directBatteryPowerMilliwatts: 0, directSystemLoadMilliwatts: 10000,
        healthCondition: "Check Battery", healthEstimate: "Poor")
}
func historyPoint(at date: Date = testDate) -> HistoryPoint { HistoryPoint(snapshot: PowerMath.snapshot(from: telemetry(at: date))) }

struct FixedClock: MonitorClock {
    var now: Date = testDate
    func sleep(seconds: TimeInterval) async throws { try await Task.sleep(for: .seconds(seconds)) }
}

final class MutableClock: MonitorClock, @unchecked Sendable {
    private let lock = NSLock()
    private var date = testDate
    var now: Date { lock.withLock { date } }
    func advance(_ seconds: TimeInterval) { lock.withLock { date = date.addingTimeInterval(seconds) } }
    func sleep(seconds: TimeInterval) async throws { try await Task.sleep(for: .seconds(seconds)) }
}

@MainActor
struct TestPreferences {
    let name = "BatteryFlowTests.\(UUID().uuidString)"
    let defaults: UserDefaults
    let value: AppPreferences
    init() {
        defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        value = AppPreferences(defaults: defaults)
    }
    func cleanup() { defaults.removePersistentDomain(forName: name) }
}

final class MemoryHistoryFiles: HistoryFileAccess, @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: Data?
    private var readFailure = false
    private var appendFailures = 0
    private var partialBytes: Int?
    private var replaceFailure = false
    private var savedBackups: [Data] = []
    init(_ data: Data? = nil) { bytes = data }
    var data: Data? { lock.withLock { bytes } }
    var backups: [Data] { lock.withLock { savedBackups } }
    func failReads(_ value: Bool) { lock.withLock { readFailure = value } }
    func failReplace(_ value: Bool) { lock.withLock { replaceFailure = value } }
    func failNextAppend(afterBytes count: Int? = nil) {
        lock.withLock { appendFailures = 1; partialBytes = count }
    }
    func read(_ url: URL) throws -> Data? {
        try lock.withLock {
            if readFailure { throw HealthReadError.failed("Read failed") }
            return bytes
        }
    }
    func append(_ data: Data, to url: URL) throws {
        try lock.withLock {
            if appendFailures > 0 {
                appendFailures -= 1
                if let count = partialBytes { bytes = (bytes ?? Data()) + data.prefix(count) }
                throw HealthReadError.failed("Append failed")
            }
            bytes = (bytes ?? Data()) + data
        }
    }
    func replace(_ data: Data, at url: URL) throws {
        try lock.withLock {
            if replaceFailure { throw HealthReadError.failed("Replace failed") }
            bytes = data
        }
    }
    func backup(_ url: URL) throws -> URL {
        lock.withLock { savedBackups.append(bytes ?? Data()) }
        return url.appendingPathExtension("backup")
    }
}
func encodeHistory(_ points: [HistoryPoint]) throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .millisecondsSince1970
    return try points.reduce(into: Data()) { data, point in
        data.append(try encoder.encode(point))
        data.append(0x0A)
    }
}
func persistence(_ files: MemoryHistoryFiles) -> HistoryPersistence {
    HistoryPersistence(fileURL: URL(fileURLWithPath: "/test-only/history.jsonl"), files: files)
}
