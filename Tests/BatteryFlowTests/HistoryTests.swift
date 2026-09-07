import Foundation
import Testing
@testable import BatteryFlow

struct HistoryTests {
    @Test func aMissingMinuteCreatesAGraphGap() {
        let points = [-180.0, -120, 0].map { historyPoint(at: testDate.addingTimeInterval($0)) }
        let samples = HistoryAggregation.samples(points, range: .day, now: testDate)
        #expect(Set(samples.map(\.segment)).count == 2)
        #expect(Set(samples.map(\.powerSegment)).count == 2)
    }

    @Test func fullThirtyDayAggregationIsBoundedAndStableAcrossAppend() {
        var points = (0..<43_200).map { historyPoint(at: testDate.addingTimeInterval(Double($0 - 43_199) * 60)) }
        let initial = HistoryAggregation.samples(points, range: .month, now: testDate)
        #expect(initial.count <= 602)
        #expect(initial.count >= 599)
        #expect(Set(initial.map(\.segment)).count == 1)
        points.append(historyPoint(at: testDate.addingTimeInterval(60)))
        let appended = HistoryAggregation.samples(points, range: .month, now: testDate.addingTimeInterval(60))
        #expect(Set(initial.map(\.id)).intersection(appended.map(\.id)).count >= initial.count - 1)
    }

    @Test func legacySailingAndValuesArePreserved() throws {
        var original = try #require(JSONSerialization.jsonObject(with: encodeHistory([historyPoint()])) as? [String: Any])
        for key in ["schemaVersion", "quality", "adapterSource", "batterySource", "systemSource"] { original.removeValue(forKey: key) }
        original["state"] = "sailing"
        original["adapterPowerWatts"] = 75.0
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let point = try decoder.decode(HistoryPoint.self, from: JSONSerialization.data(withJSONObject: original))
        #expect(point.state == .paused)
        #expect(point.quality == .legacy)
        #expect(point.adapterSource == .legacy)
        #expect(point.adapterPowerWatts == 75)
        #expect(point.timestamp == testDate)
        #expect(!point.powerIsConsistent)
        let samples = HistoryAggregation.samples([point], range: .day, now: testDate)
        #expect(samples.first?.adapter == nil)
        #expect(samples.first?.charge == 80)
    }

    @Test func corruptedLinesAreBackedUpBeforeRecovery() async throws {
        let original = try encodeHistory([historyPoint(at: testDate.addingTimeInterval(-120))]) + Data("{broken\n".utf8)
        let files = MemoryHistoryFiles(original)
        let store = persistence(files)
        let status = await store.synchronize(now: testDate, retentionDays: 30, point: historyPoint())
        #expect(status.error == nil)
        #expect(status.points.count == 2)
        #expect(status.warning != nil)
        #expect(files.backups == [original])
        #expect(files.data?.split(separator: 0x0A).count == 2)
    }

    @Test func unreadableAndWhollyDamagedFilesAreNeverOverwritten() async {
        let original = Data("not history\n".utf8)
        let files = MemoryHistoryFiles(original)
        let store = persistence(files)
        let first = await store.synchronize(now: testDate, retentionDays: 30, point: historyPoint())
        #expect(first.error != nil)
        #expect(first.pendingCount == 1)
        #expect(files.data == original)
        files.failReads(true)
        let second = await store.synchronize(now: testDate.addingTimeInterval(60), retentionDays: 30)
        #expect(second.error != nil)
        #expect(files.data == original)
        #expect(second.points.count == 1)
    }

    @Test func futureSchemaIsLeftUntouched() async throws {
        var json = try #require(JSONSerialization.jsonObject(with: encodeHistory([historyPoint()])) as? [String: Any])
        json["schemaVersion"] = 99
        let bytes = try JSONSerialization.data(withJSONObject: json) + Data([10])
        let files = MemoryHistoryFiles(bytes)
        let status = await persistence(files).synchronize(now: testDate, retentionDays: 30)
        #expect(status.error != nil)
        #expect(files.data == bytes)
    }

    @Test func failedAndAmbiguousAppendsRetryWithoutDuplicates() async throws {
        let files = MemoryHistoryFiles()
        let store = persistence(files)
        files.failNextAppend(afterBytes: 100_000) // all bytes land, but the operation reports failure
        let point = historyPoint()
        let failed = await store.synchronize(now: testDate, retentionDays: 30, point: point)
        #expect(failed.pendingCount == 1)
        #expect(failed.error != nil)
        let recovered = await store.synchronize(now: testDate, retentionDays: 30)
        #expect(recovered.error == nil)
        #expect(recovered.pendingCount == 0)
        #expect(recovered.points.map(\.id) == [point.id])
        #expect(files.data?.split(separator: 0x0A).count == 1)
    }

    @Test func partialAppendRepairsTailAndPreservesPending() async throws {
        let first = historyPoint(at: testDate.addingTimeInterval(-120))
        let files = MemoryHistoryFiles(try encodeHistory([first]))
        let store = persistence(files)
        files.failNextAppend(afterBytes: 40)
        let next = historyPoint()
        let failed = await store.synchronize(now: testDate, retentionDays: 30, point: next)
        #expect(failed.error != nil)
        let recovered = await store.synchronize(now: testDate, retentionDays: 30)
        #expect(recovered.error == nil)
        #expect(recovered.points.map(\.id) == [first.id, next.id])
        #expect(files.backups.count == 1)
        #expect(files.data?.split(separator: 0x0A).count == 2)
    }

    @Test func retentionAndClearAreTransactional() async throws {
        let older = historyPoint(at: testDate.addingTimeInterval(-2 * 86400))
        let recent = historyPoint(at: testDate.addingTimeInterval(-120))
        let files = MemoryHistoryFiles(try encodeHistory([older, recent]))
        let store = persistence(files)
        let initial = await store.synchronize(now: testDate, retentionDays: 30)
        #expect(initial.points.count == 2)
        let pruned = await store.synchronize(now: testDate, retentionDays: 1)
        #expect(pruned.points.map(\.id) == [recent.id])
        files.failReplace(true)
        let failed = await store.clear(now: testDate)
        #expect(failed.error != nil)
        #expect(failed.points.count == 1)
        files.failReplace(false)
        let cleared = await store.clear(now: testDate)
        #expect(cleared.points.isEmpty)
        #expect(files.data == Data())
        let stale = await store.synchronize(now: testDate, retentionDays: 1, point: recent)
        #expect(stale.points.isEmpty)
    }

    @Test func loadAppendAndClearCanRunConcurrently() async throws {
        let files = MemoryHistoryFiles(try encodeHistory([historyPoint(at: testDate.addingTimeInterval(-180))]))
        let store = persistence(files)
        async let load = store.synchronize(now: testDate, retentionDays: 30)
        async let append = store.synchronize(now: testDate, retentionDays: 30, point: historyPoint(at: testDate.addingTimeInterval(-60)))
        async let clear = store.clear(now: testDate)
        _ = await (load, append, clear)
        let final = await store.synchronize(now: testDate, retentionDays: 30)
        #expect(final.points.isEmpty)
        #expect(final.pendingCount == 0)
        #expect(files.data == Data())
    }

    @Test func oneSamplePerMinuteAndDuplicatesAreSuppressed() async {
        let files = MemoryHistoryFiles()
        let store = persistence(files)
        for offset in [0.0, 1, 59, 60, 61, 120] {
            _ = await store.synchronize(now: testDate.addingTimeInterval(offset), retentionDays: 30,
                point: historyPoint(at: testDate.addingTimeInterval(offset)))
        }
        #expect(files.data?.split(separator: 0x0A).count == 3)
    }

    @Test func aggregationIsStableAndPreservesGaps() {
        let points = [-1200.0, -1140, -300, -240].map { historyPoint(at: testDate.addingTimeInterval($0)) }
        let first = HistoryAggregation.samples(points, range: .day, now: testDate)
        let second = HistoryAggregation.samples(points, range: .day, now: testDate)
        #expect(first == second)
        #expect(Set(first.map(\.segment)).count == 2)
        #expect(Set(first.map(\.powerSegment)).count == 2)
        #expect(first.allSatisfy { $0.battery == 0 })
    }

    @Test @MainActor func recordingPausePreservesExistingHistoryAndPreferences() async throws {
        let pref = TestPreferences()
        defer { pref.cleanup() }
        let files = MemoryHistoryFiles(try encodeHistory([historyPoint(at: testDate.addingTimeInterval(-120))]))
        let store = HistoryStore(preferences: pref.value, fileURL: URL(fileURLWithPath: "/test-only/history"), files: files, clock: FixedClock())
        await store.load()
        pref.value.recordingEnabled = false
        await store.record(PowerMath.snapshot(from: telemetry()))
        #expect(store.points.count == 1)
        #expect(files.data?.split(separator: 0x0A).count == 1)
        #expect(store.errorMessage == nil)
    }

    @Test func localFilesRoundTripUsesOnlyTemporaryDirectory() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("BatteryFlowTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.jsonl")
        let store = HistoryPersistence(fileURL: url)
        let written = await store.synchronize(now: testDate, retentionDays: 30, point: historyPoint())
        #expect(written.error == nil)
        let reopened = await HistoryPersistence(fileURL: url).synchronize(now: testDate, retentionDays: 30)
        #expect(reopened.points == written.points)
    }
}
