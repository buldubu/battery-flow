import Foundation
import SwiftUI
import Combine

struct HistoryPoint: Codable, Identifiable, Equatable, Sendable {
    var schemaVersion: Int
    let id: UUID
    let timestamp: Date
    var adapterPowerWatts: Double?
    var batteryPowerWatts: Double?
    var systemPowerWatts: Double?
    var chargePercent: Int?
    var temperatureCelsius: Double?
    var externalConnected: Bool?
    var state: PowerState
    var quality: PowerQuality
    var adapterSource: ReadingSource
    var batterySource: ReadingSource
    var systemSource: ReadingSource

    init(snapshot: PowerSnapshot) {
        schemaVersion = 2
        id = UUID()
        timestamp = snapshot.timestamp ?? .distantPast
        adapterPowerWatts = snapshot.adapterPowerWatts
        batteryPowerWatts = snapshot.batteryPowerWatts
        systemPowerWatts = snapshot.systemPowerWatts
        chargePercent = snapshot.chargePercent
        temperatureCelsius = snapshot.temperatureCelsius
        externalConnected = snapshot.externalConnected
        state = snapshot.state
        quality = snapshot.quality
        adapterSource = snapshot.adapter.source
        batterySource = snapshot.battery.source
        systemSource = snapshot.system.source
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, timestamp, adapterPowerWatts, batteryPowerWatts, systemPowerWatts
        case chargePercent, temperatureCelsius, externalConnected, state, quality, adapterSource, batterySource, systemSource
    }
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        guard schemaVersion <= 2 else {
            throw DecodingError.dataCorruptedError(forKey: .schemaVersion, in: c, debugDescription: "History is from a newer version.")
        }
        id = try c.decode(UUID.self, forKey: .id)
        timestamp = try c.decode(Date.self, forKey: .timestamp)
        adapterPowerWatts = try c.decodeIfPresent(Double.self, forKey: .adapterPowerWatts)
        batteryPowerWatts = try c.decodeIfPresent(Double.self, forKey: .batteryPowerWatts)
        systemPowerWatts = try c.decodeIfPresent(Double.self, forKey: .systemPowerWatts)
        chargePercent = try c.decodeIfPresent(Int.self, forKey: .chargePercent)
        temperatureCelsius = try c.decodeIfPresent(Double.self, forKey: .temperatureCelsius)
        externalConnected = try c.decodeIfPresent(Bool.self, forKey: .externalConnected)
        state = try c.decode(PowerState.self, forKey: .state)
        quality = try c.decodeIfPresent(PowerQuality.self, forKey: .quality) ?? .legacy
        adapterSource = try c.decodeIfPresent(ReadingSource.self, forKey: .adapterSource) ?? .legacy
        batterySource = try c.decodeIfPresent(ReadingSource.self, forKey: .batterySource) ?? .legacy
        systemSource = try c.decodeIfPresent(ReadingSource.self, forKey: .systemSource) ?? .legacy
    }
    var powerIsConsistent: Bool {
        quality != .inconsistent && PowerMath.consistent(
            adapter: adapterPowerWatts, battery: batteryPowerWatts, system: systemPowerWatts, externalConnected: externalConnected)
    }
}

struct HistoryStatus: Sendable {
    var revision: Int
    var points: [HistoryPoint]
    var pendingCount: Int
    var error: String?
    var warning: String?
}

protocol HistoryFileAccess: Sendable {
    func read(_ url: URL) throws -> Data?
    func append(_ data: Data, to url: URL) throws
    func replace(_ data: Data, at url: URL) throws
    func backup(_ url: URL) throws -> URL
}

struct LocalHistoryFiles: HistoryFileAccess {
    func read(_ url: URL) throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }
    func append(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) { try Data().write(to: url, options: .atomic) }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }
    func replace(_ data: Data, at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
    func backup(_ url: URL) throws -> URL {
        let backup = url.deletingLastPathComponent().appendingPathComponent("power-history-recovery-\(UUID().uuidString).jsonl")
        try FileManager.default.copyItem(at: url, to: backup)
        return backup
    }
}

/// No suspension points inside a transaction: loading, recovery, append, prune and clear are serialized.
actor HistoryPersistence {
    let fileURL: URL
    private let files: any HistoryFileAccess
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var points: [HistoryPoint] = []
    private var pending: [HistoryPoint] = []
    private var loaded = false
    private var rewriteRequired = false
    private var recoveringOwnWrite = false
    private var warning: String?
    private var revision = 0
    private var lastPrune = Date.distantPast
    private var retentionDays = 30
    private var clearedAt = Date.distantPast
    static let sampleInterval: TimeInterval = 60

    init(fileURL: URL, files: any HistoryFileAccess = LocalHistoryFiles()) {
        self.fileURL = fileURL
        self.files = files
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
    }

    func synchronize(now: Date, retentionDays: Int, point: HistoryPoint? = nil) -> HistoryStatus {
        var failure: String?
        do { try loadIfNeeded() } catch { failure = error.localizedDescription }
        if let point, point.timestamp > clearedAt,
           points.last.map({ point.timestamp.timeIntervalSince($0.timestamp) >= Self.sampleInterval }) ?? true {
            points.append(point)
            pending.append(point)
        }
        // Failed reads can outlast a retention boundary between scheduled disk prunes.
        let cutoff = now.addingTimeInterval(-Double(retentionDays) * 86400)
        let expiredPending = Set(pending.filter { $0.timestamp < cutoff }.map(\.id))
        if !expiredPending.isEmpty {
            pending.removeAll { expiredPending.contains($0.id) }
            points.removeAll { expiredPending.contains($0.id) }
        }
        if self.retentionDays != retentionDays || now.timeIntervalSince(lastPrune) >= 6 * 3600 {
            self.retentionDays = retentionDays
            lastPrune = now
            let retained = points.filter { $0.timestamp >= cutoff }
            if retained.count != points.count { rewriteRequired = true }
            points = retained
            pending.removeAll { $0.timestamp < cutoff }
        }
        if failure == nil {
            do {
                if rewriteRequired {
                    try files.replace(encode(points), at: fileURL)
                    rewriteRequired = false
                    pending = []
                } else if !pending.isEmpty {
                    try files.append(encode(pending), to: fileURL)
                    pending = []
                }
            } catch {
                // A partial write may have succeeded. Reconcile IDs against disk before retrying.
                loaded = false
                recoveringOwnWrite = true
                failure = error.localizedDescription
            }
        }
        revision += 1
        return status(error: failure)
    }

    func clear(now: Date) -> HistoryStatus {
        do {
            try files.replace(Data(), at: fileURL)
            points = []
            pending = []
            warning = nil
            loaded = true
            rewriteRequired = false
            recoveringOwnWrite = false
            clearedAt = now
            revision += 1
            return status(error: nil)
        } catch {
            revision += 1
            return status(error: error.localizedDescription)
        }
    }

    private func status(error: String?) -> HistoryStatus {
        HistoryStatus(revision: revision, points: points, pendingCount: pending.count, error: error, warning: warning)
    }

    private func loadIfNeeded() throws {
        guard !loaded else { return }
        let data = try files.read(fileURL) ?? Data()
        var disk: [HistoryPoint] = []
        var damaged = 0
        for line in data.split(separator: 0x0A) {
            do { disk.append(try decoder.decode(HistoryPoint.self, from: Data(line))) }
            catch {
                // Preserve unknown future formats rather than rewriting them.
                if let json = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                   let version = json["schemaVersion"] as? Int, version > 2 {
                    throw HealthReadError.failed("History was written by a newer app. The file has been left untouched.")
                }
                damaged += 1
            }
        }
        guard data.isEmpty || !disk.isEmpty || (recoveringOwnWrite && !pending.isEmpty) else {
            throw HealthReadError.failed("History could not be decoded. The original file has been left untouched.")
        }
        if damaged > 0 || (!data.isEmpty && data.last != 0x0A) {
            let backup = try files.backup(fileURL)
            warning = "Recovered \(disk.count) samples; \(damaged) damaged lines. Original saved as \(backup.lastPathComponent)."
            rewriteRequired = true
        }
        let savedIDs = Set(disk.map(\.id))
        pending.removeAll { savedIDs.contains($0.id) }
        var seen = Set<UUID>()
        points = (disk + pending).sorted { $0.timestamp < $1.timestamp }.filter { seen.insert($0.id).inserted }
        loaded = true
        recoveringOwnWrite = false
        // A retry must reapply retention after it reloads the on-disk copy.
        lastPrune = .distantPast
    }
    private func encode(_ points: [HistoryPoint]) throws -> Data {
        var data = Data()
        for point in points {
            data.append(try encoder.encode(point))
            data.append(0x0A)
        }
        return data
    }
}

struct ChartSample: Identifiable, Equatable {
    let id: UUID
    let timestamp: Date
    let segment: UUID
    let powerSegment: UUID
    let adapter: Double?
    let battery: Double?
    let system: Double?
    let charge: Double?
    let temperature: Double?
}

enum HistoryAggregation {
    static func samples(_ points: [HistoryPoint], range: HistoryRange, now: Date, maximum: Int = 600) -> [ChartSample] {
        let filtered = points.filter { $0.timestamp >= now.addingTimeInterval(-range.duration) && $0.timestamp <= now }
        guard let first = filtered.first else { return [] }
        // Fixed time buckets keep identity stable as new records arrive.
        let width = max(60, range.duration / Double(max(2, maximum)))
        var output: [ChartSample] = []
        var bucket: [HistoryPoint] = []
        var bucketIndex: Int?
        var segment = first.id
        var powerSegment = first.id
        var previous: HistoryPoint?
        func flush() {
            guard let first = bucket.first else { return }
            func mean(_ values: [Double]) -> Double? { values.isEmpty ? nil : values.reduce(0, +) / Double(values.count) }
            let validPower = bucket.filter(\.powerIsConsistent)
            output.append(ChartSample(id: first.id, timestamp: first.timestamp, segment: segment, powerSegment: powerSegment,
                adapter: mean(validPower.compactMap(\.adapterPowerWatts)),
                battery: mean(validPower.compactMap(\.batteryPowerWatts)),
                system: mean(validPower.compactMap(\.systemPowerWatts)),
                charge: mean(bucket.compactMap { $0.chargePercent.flatMap { (0...100).contains($0) ? Double($0) : nil } }),
                temperature: mean(bucket.compactMap { $0.temperatureCelsius.flatMap { PowerMath.valid($0, in: -20...100) } })))
            bucket = []
        }
        for point in filtered {
            let index = Int(point.timestamp.timeIntervalSince1970 / width)
            let gap = previous.map { point.timestamp.timeIntervalSince($0.timestamp) >= 120 } ?? false
            let powerBreak = previous.map { !$0.powerIsConsistent || !point.powerIsConsistent
                || $0.adapterPowerWatts == nil || point.adapterPowerWatts == nil
                || $0.batteryPowerWatts == nil || point.batteryPowerWatts == nil
                || $0.systemPowerWatts == nil || point.systemPowerWatts == nil } ?? false
            if index != bucketIndex || gap || powerBreak { flush() }
            if gap { segment = point.id }
            if gap || powerBreak { powerSegment = point.id }
            bucketIndex = index
            bucket.append(point)
            previous = point
        }
        flush()
        return output
    }
}

@MainActor
final class HistoryStore: ObservableObject {
    @Published private(set) var points: [HistoryPoint] = []
    @Published private(set) var isLoading = true
    @Published private(set) var errorMessage: String?
    @Published private(set) var recoveryWarning: String?
    @Published private(set) var pendingCount = 0
    @Published private(set) var excludedPowerCount = 0
    private let persistence: HistoryPersistence
    private let preferences: AppPreferences
    private let clock: any MonitorClock
    private var revision = -1
    private var chartRevision = 0
    private var lastRecordAttempt = Date.distantPast
    private var cache: [HistoryRange: (Int, Int, [ChartSample])] = [:]
    private var subscriptions = Set<AnyCancellable>()

    init(preferences: AppPreferences, fileURL: URL? = nil, files: any HistoryFileAccess = LocalHistoryFiles(),
         clock: any MonitorClock = SystemMonitorClock()) {
        self.preferences = preferences
        self.clock = clock
        let url = fileURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BatteryFlow/power-history.jsonl")
        persistence = HistoryPersistence(fileURL: url, files: files)
        preferences.$retentionDays.dropFirst().sink { [weak self] days in
            Task { @MainActor [weak self] in await self?.retry(retentionDays: days) }
        }.store(in: &subscriptions)
    }
    func load() async { await retry() }
    func record(_ snapshot: PowerSnapshot) async {
        guard snapshot.timestamp != nil, !snapshot.isStale else { return }
        guard clock.now.timeIntervalSince(lastRecordAttempt) >= 60 else { return }
        lastRecordAttempt = clock.now
        let point = preferences.recordingEnabled && snapshot.state != .unavailable ? HistoryPoint(snapshot: snapshot) : nil
        apply(await persistence.synchronize(now: clock.now, retentionDays: preferences.retentionDays, point: point))
    }
    func retry(retentionDays: Int? = nil) async {
        apply(await persistence.synchronize(now: clock.now, retentionDays: retentionDays ?? preferences.retentionDays))
    }
    func clear() async { apply(await persistence.clear(now: clock.now)) }
    func countOlder(than days: Int) -> Int {
        let cutoff = clock.now.addingTimeInterval(-Double(days) * 86400)
        return points.filter { $0.timestamp < cutoff }.count
    }
    func chartSamples(in range: HistoryRange) -> [ChartSample] {
        let minute = Int(clock.now.timeIntervalSince1970 / 60)
        if let entry = cache[range], entry.0 == chartRevision, entry.1 == minute { return entry.2 }
        let data = HistoryAggregation.samples(points, range: range, now: clock.now)
        cache[range] = (chartRevision, minute, data)
        return data
    }
    private func apply(_ status: HistoryStatus) {
        guard status.revision >= revision else { return }
        if isLoading { isLoading = false }
        if errorMessage != status.error { errorMessage = status.error }
        if recoveryWarning != status.warning { recoveryWarning = status.warning }
        if pendingCount != status.pendingCount { pendingCount = status.pendingCount }
        // Avoid publishing the entire history on live, sub-minute telemetry refreshes.
        if points != status.points {
            points = status.points
            chartRevision += 1
            excludedPowerCount = points.filter { !$0.powerIsConsistent }.count
            cache = [:]
        }
        revision = status.revision
    }
}
