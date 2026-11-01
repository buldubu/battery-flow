import Foundation
import Testing
@testable import BatteryFlow

struct HistoryInspectionTests {
    @Test func rangeExcludesExpiredAndFutureObservationsAndIncludesBoundaries() {
        let offsets = [-3601.0, -3600, -60, 0, 1]
        let points = offsets.map { historyPoint(at: testDate.addingTimeInterval($0)) }
        let selected = HistoryAnalysis.observations(points, in: .hour, now: testDate)
        #expect(selected.map(\.id) == Array(points[1...3]).map(\.id))
    }

    @Test func inspectionSnapsToRecordedSamplesAcrossGapsAndReportsAveraging() throws {
        let points = [-1800.0, -1740, -1680, -60, 0].map { historyPoint(at: testDate.addingTimeInterval($0)) }
        let samples = HistoryAggregation.samples(points, range: .month, now: testDate)
        let first = try #require(samples.first)
        #expect(first.observationCount == 3)
        #expect(first.timestamp == points[0].timestamp)
        #expect(first.endTimestamp == points[2].timestamp)
        #expect(Set(samples.map(\.segment)).count == 2)
        let nearest = HistoryAnalysis.nearest(to: testDate.addingTimeInterval(-100), in: samples)
        #expect(nearest?.timestamp == points[3].timestamp)
        #expect(HistoryAnalysis.nearest(to: testDate, in: []) == nil)
    }

    @Test func summariesUseRawValidObservationsAndKeepLegitimateZeros() throws {
        var first = historyPoint()
        first.systemPowerWatts = 0
        first.adapterPowerWatts = 0
        var second = historyPoint()
        second.systemPowerWatts = 30
        second.adapterPowerWatts = 30
        var invalid = historyPoint()
        invalid.systemPowerWatts = 100
        invalid.chargePercent = 101
        invalid.temperatureCelsius = .infinity
        let summary = HistorySummary(points: [first, second, invalid])
        #expect(summary.count == 3)
        #expect(summary.mac.average == 15)
        #expect(summary.mac.peak == 30)
        #expect(summary.charge.average == 80)
        #expect(abs(try #require(summary.temperature.average) - 30.05) < 0.001)
        #expect(HistorySummary(points: []).mac.average == nil)
    }

    @Test func csvContainsRawObservationsInUTCWithStableColumnsAndMissingValues() throws {
        var partial = historyPoint(at: testDate.addingTimeInterval(-60))
        partial.quality = .partial
        partial.batteryPowerWatts = nil
        partial.batterySource = .unavailable
        partial.temperatureCelsius = nil
        partial.externalConnected = nil
        let current = historyPoint()
        let data = HistoryCSV.encode([current, partial])
        let csv = try #require(String(data: data, encoding: .utf8))
        let lines = csv.components(separatedBy: "\r\n")
        #expect(lines.count == 4)
        #expect(lines.last == "")
        let header = lines[0].components(separatedBy: ",")
        #expect(header.count == 15)
        #expect(header[0] == "timestamp_utc")
        #expect(header[4] == "temperature_celsius")
        let row = lines[1].components(separatedBy: ",")
        #expect(row.count == header.count)
        #expect(row[0].hasSuffix("Z"))
        #expect(ISO8601DateFormatter.withFractions.date(from: row[0]) == partial.timestamp)
        #expect(row[1] == partial.id.uuidString)
        #expect(row[4] == "")
        #expect(row[5] == "10.0")
        #expect(row[6] == "")
        #expect(row[8] == "")
        #expect(row[10] == "partial")
        #expect(row[13] == "unavailable")
        #expect(lines[2].contains(current.id.uuidString))
        #expect(HistoryCSV.encode([]).split(separator: 0x0A).count == 1)
    }

    @Test func csvPreservesQualityWhileExcludingInvalidLegacyPower() throws {
        var invalid = historyPoint()
        invalid.quality = .legacy
        invalid.adapterPowerWatts = 100
        invalid.chargePercent = -1
        invalid.temperatureCelsius = 200
        let csv = try #require(String(data: HistoryCSV.encode([invalid]), encoding: .utf8))
        let row = csv.components(separatedBy: "\r\n")[1].components(separatedBy: ",")
        #expect(Array(row[3...7]) == ["", "", "", "", ""])
        #expect(row[10] == "legacy")
        #expect(row[11] == "false")
    }
}

private extension ISO8601DateFormatter {
    static var withFractions: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }
}
