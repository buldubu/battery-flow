import Foundation

enum HistoryAnalysis {
    static func observations(_ points: [HistoryPoint], in range: HistoryRange, now: Date) -> [HistoryPoint] {
        let start = now.addingTimeInterval(-range.duration)
        return points.filter { $0.timestamp >= start && $0.timestamp <= now }
    }

    static func nearest(to date: Date, in samples: [ChartSample]) -> ChartSample? {
        samples.min { abs($0.timestamp.timeIntervalSince(date)) < abs($1.timestamp.timeIntervalSince(date)) }
    }
}

/// Chart-only convention: sources are positive, consumers are negative.
/// Recorded battery power uses the opposite sign (positive means charging).
struct HistoryPowerFlow {
    let adapter: Double?
    let mac: Double?
    let battery: Double?

    init(adapter: Double?, system: Double?, battery: Double?) {
        self.adapter = adapter
        mac = system.map { $0 == 0 ? 0 : -$0 }
        self.battery = battery.map { $0 == 0 ? 0 : -$0 }
    }

    var batteryLabel: String {
        guard let battery else { return "—" }
        guard abs(battery) > 0.2 else { return "Idle" }
        return (battery < 0 ? "Charging " : "Discharging ") + ReadingFormat.watts(abs(battery))
    }
}

struct MetricStatistics {
    let average: Double?
    let peak: Double?

    init(_ values: [Double]) {
        average = values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
        peak = values.max()
    }
}

struct HistorySummary {
    let count: Int
    let mac: MetricStatistics
    let charge: MetricStatistics
    let temperature: MetricStatistics

    init(points: [HistoryPoint]) {
        count = points.count
        mac = MetricStatistics(points.filter(\.powerIsConsistent).compactMap(\.systemPowerWatts))
        charge = MetricStatistics(points.compactMap { $0.chargePercent.flatMap { (0...100).contains($0) ? Double($0) : nil } })
        temperature = MetricStatistics(points.compactMap { $0.temperatureCelsius.flatMap { PowerMath.valid($0, in: -20...100) } })
    }
}

enum HistoryCSV {
    static func encode(_ points: [HistoryPoint]) -> Data {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        var csv = "timestamp_utc,id,schema_version,charge_percent,temperature_celsius,adapter_power_watts,battery_power_watts,system_power_watts,external_connected,state,quality,power_consistent,adapter_source,battery_source,system_source\r\n"
        func number(_ value: Double?) -> String { value.map { String($0) } ?? "" }
        for point in points.sorted(by: { $0.timestamp < $1.timestamp }) {
            let valid = point.powerIsConsistent
            let charge = point.chargePercent.flatMap { (0...100).contains($0) ? String($0) : nil } ?? ""
            let temperature = point.temperatureCelsius.flatMap { PowerMath.valid($0, in: -20...100) }
            let row = [formatter.string(from: point.timestamp), point.id.uuidString, String(point.schemaVersion),
                charge, number(temperature), number(valid ? point.adapterPowerWatts : nil),
                number(valid ? point.batteryPowerWatts : nil), number(valid ? point.systemPowerWatts : nil),
                point.externalConnected.map { $0 ? "true" : "false" } ?? "", point.state.rawValue,
                point.quality.rawValue, valid ? "true" : "false", point.adapterSource.rawValue,
                point.batterySource.rawValue, point.systemSource.rawValue]
            csv += row.map(escape).joined(separator: ",") + "\r\n"
        }
        return Data(csv.utf8)
    }

    private static func escape(_ value: String) -> String {
        value.contains(where: { ",\"\r\n".contains($0) })
            ? "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : value
    }
}
