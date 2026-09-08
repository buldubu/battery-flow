import Foundation

enum PowerState: String, Codable, Sendable {
    case onBattery, charging, charged, paused, supplementing, unavailable

    init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = value == "sailing" ? .paused : (Self(rawValue: value) ?? .unavailable)
    }

    var title: String {
        switch self {
        case .onBattery: "On Battery"
        case .charging: "Charging"
        case .charged: "Fully Charged"
        case .paused: "Sailing"
        case .supplementing: "Adapter + Battery"
        case .unavailable: "Telemetry Unavailable"
        }
    }
    var detail: String {
        switch self {
        case .onBattery: "Battery is powering the Mac"
        case .charging: "Adapter is powering the Mac and charging the battery"
        case .charged: "Connected to power; the battery reports a full charge"
        case .paused: "Connected to power; the battery is not charging"
        case .supplementing: "Adapter and battery are both powering the Mac"
        case .unavailable: "Live battery telemetry is unavailable"
        }
    }
    var icon: String {
        switch self {
        case .onBattery: "battery.50percent"
        case .charging: "bolt.fill"
        case .charged: "checkmark.circle"
        case .paused: "sailboat.fill"
        case .supplementing: "arrow.triangle.merge"
        case .unavailable: "questionmark.circle"
        }
    }
}

enum ReadingSource: String, Codable, Sendable { case reported, calculated, unavailable, legacy }
enum PowerQuality: String, Codable, Sendable { case valid, partial, inconsistent, legacy }

struct PowerReading: Equatable, Sendable {
    var watts: Double?
    var source: ReadingSource
    static let unavailable = PowerReading(watts: nil, source: .unavailable)

    init(_ watts: Double, source: ReadingSource = .reported) {
        self.watts = watts
        self.source = source
    }
    private init(watts: Double?, source: ReadingSource) {
        self.watts = watts
        self.source = source
    }
}

struct PowerSnapshot: Equatable, Sendable {
    var timestamp: Date?
    var state: PowerState = .unavailable
    var chargePercent: Int?
    var hardwarePercent: Double?
    var temperatureCelsius: Double?
    var cycleCount: Int?
    var externalConnected: Bool?
    var isCharging: Bool?
    var isFullyCharged: Bool?
    var adapterRatingWatts: Double?
    var adapter: PowerReading = .unavailable
    var battery: PowerReading = .unavailable
    var system: PowerReading = .unavailable
    var quality: PowerQuality = .partial
    var isStale = false
    var errorMessage: String?

    var adapterPowerWatts: Double? { adapter.watts }
    var batteryPowerWatts: Double? { battery.watts }
    var systemPowerWatts: Double? { system.watts }
    var chargeText: String { chargePercent.map { "\($0)%" } ?? "—" }
    var canAnimate: Bool {
        guard !isStale, state != .unavailable, quality != .inconsistent else { return false }
        return abs(battery.watts ?? 0) > 0.2 || ((adapter.watts ?? 0) > 0.05 && (system.watts ?? 0) > 0.05)
    }
    var isCalculated: Bool { [adapter.source, battery.source, system.source].contains(.calculated) }
    var batteryIcon: String {
        guard let percent = chargePercent else { return "battery.0percent" }
        switch percent {
        case 88...: return "battery.100percent"
        case 63...: return "battery.75percent"
        case 38...: return "battery.50percent"
        case 13...: return "battery.25percent"
        default: return "battery.0percent"
        }
    }

    func stale(message: String) -> Self {
        var copy = self
        copy.isStale = true
        copy.state = .unavailable
        copy.adapter = .unavailable
        copy.battery = .unavailable
        copy.system = .unavailable
        copy.quality = .partial
        copy.errorMessage = message
        return copy
    }
    static let empty = PowerSnapshot()
}

struct RawPowerTelemetry: Sendable {
    var timestamp = Date()
    var chargePercent: Int?
    var rawCurrentCapacity: Int64?
    var rawMaxCapacity: Int64?
    var rawTemperature: Int64?
    var cycleCount: Int?
    var externalConnected: Bool?
    var isCharging: Bool?
    var isFullyCharged: Bool?
    var voltageMillivolts: Int64?
    var amperageMilliamps: Int64?
    var adapterRatingWatts: Int64?
    var systemVoltageInMillivolts: Int64?
    var systemCurrentInMilliamps: Int64?
    var directAdapterPowerMilliwatts: Int64?
    var directBatteryPowerMilliwatts: Int64?
    var directSystemLoadMilliwatts: Int64?
    var healthCondition: String?
    var healthEstimate: String?
}

enum PowerMath {
    static let tolerance = 1.0

    static func snapshot(from raw: RawPowerTelemetry) -> PowerSnapshot {
        var battery = power(raw.directBatteryPowerMilliwatts, signed: true)
        if battery.watts == nil {
            battery = voltagePower(raw.voltageMillivolts, raw.amperageMilliamps, signed: true)
        }
        var adapter = power(raw.directAdapterPowerMilliwatts)
        if adapter.watts == nil {
            adapter = voltagePower(raw.systemVoltageInMillivolts, raw.systemCurrentInMilliamps)
        }
        var system = power(raw.directSystemLoadMilliwatts)
        if raw.externalConnected == false, adapter.watts == nil { adapter = PowerReading(0, source: .calculated) }
        if raw.externalConnected == nil {
            adapter = .unavailable
            battery = .unavailable
            system = .unavailable
        }
        if system.watts == nil, let a = adapter.watts, let b = battery.watts { system = calculated(a - b) }
        if adapter.watts == nil, let s = system.watts, let b = battery.watts { adapter = calculated(s + b) }
        if battery.watts == nil, let a = adapter.watts, let s = system.watts { battery = calculated(a - s, signed: true) }

        var quality: PowerQuality = [adapter, battery, system].allSatisfy { $0.watts != nil } ? .valid : .partial
        if !consistent(adapter: adapter.watts, battery: battery.watts, system: system.watts,
                       externalConnected: raw.externalConnected) {
            quality = .inconsistent
            adapter = .unavailable
            battery = .unavailable
            system = .unavailable
        }
        let capacity: Double? = {
            guard let current = raw.rawCurrentCapacity, let max = raw.rawMaxCapacity,
                  current >= 0, max > 0, max <= 100_000, current <= max else { return nil }
            return valid(Double(current) / Double(max) * 100, in: 0...100)
        }()
        return PowerSnapshot(
            timestamp: raw.timestamp,
            state: classify(externalConnected: raw.externalConnected, isCharging: raw.isCharging,
                            isFullyCharged: raw.isFullyCharged, batteryPowerWatts: battery.watts,
                            adapterPowerWatts: adapter.watts),
            chargePercent: raw.chargePercent.flatMap { (0...100).contains($0) ? $0 : nil },
            hardwarePercent: capacity,
            temperatureCelsius: raw.rawTemperature.flatMap { valid(Double($0) / 10 - 273.15, in: -20...100) },
            cycleCount: raw.cycleCount.flatMap { (0...100_000).contains($0) ? $0 : nil },
            externalConnected: raw.externalConnected, isCharging: raw.isCharging, isFullyCharged: raw.isFullyCharged,
            adapterRatingWatts: raw.adapterRatingWatts.flatMap { valid(Double($0), in: 1...500) },
            adapter: adapter, battery: battery, system: system, quality: quality,
            errorMessage: quality == .inconsistent ? "Power readings disagree. Waiting for a consistent sample."
                : (raw.externalConnected == nil ? "Power source information is unavailable." : nil)
        )
    }

    static func consistent(adapter: Double?, battery: Double?, system: Double?, externalConnected: Bool?) -> Bool {
        if let a = adapter, valid(a, in: 0...250) == nil { return false }
        if let s = system, valid(s, in: 0...250) == nil { return false }
        if let b = battery, valid(b, in: -250...250) == nil { return false }
        if externalConnected == false {
            if let a = adapter, a > 0.05 { return false }
            if let b = battery, b > 0.2 { return false }
        }
        // Missing input/load must not hide a pair that would require negative input/load.
        if let a = adapter, let b = battery, system == nil, a - b < -tolerance { return false }
        if let s = system, let b = battery, adapter == nil, s + b < -tolerance { return false }
        if let a = adapter, let b = battery, let s = system { return abs(a - s - b) <= tolerance }
        return true
    }

    static func classify(externalConnected: Bool?, isCharging: Bool?, isFullyCharged: Bool? = nil,
                         batteryPowerWatts: Double?, adapterPowerWatts: Double? = nil) -> PowerState {
        guard let externalConnected else { return .unavailable }
        guard externalConnected else { return .onBattery }
        if let power = batteryPowerWatts {
            if power < -0.2 { return (adapterPowerWatts ?? 0) > 0.05 ? .supplementing : .onBattery }
            if power > 0.2 { return .charging }
            return isFullyCharged == true ? .charged : .paused
        }
        if isFullyCharged == true { return .charged }
        if isCharging == true { return .charging }
        return isCharging == false ? .paused : .unavailable
    }

    static func smooth(_ new: PowerSnapshot, previous: PowerSnapshot?) -> PowerSnapshot {
        guard let previous, !previous.isStale, new.quality == .valid, previous.quality == .valid,
              previous.state == new.state, previous.externalConnected == new.externalConnected,
              previous.isCharging == new.isCharging, previous.isFullyCharged == new.isFullyCharged,
              let date = new.timestamp, let oldDate = previous.timestamp else { return new }
        let elapsed = date.timeIntervalSince(oldDate)
        guard elapsed > 0, elapsed < 120,
              direction(previous.battery.watts) == direction(new.battery.watts),
              previous.adapter.source == new.adapter.source, previous.battery.source == new.battery.source,
              previous.system.source == new.system.source else { return new }
        let alpha = 1 - exp(-elapsed / 3)
        func blend(_ current: PowerReading, _ old: PowerReading) -> PowerReading {
            guard let c = current.watts, let p = old.watts else { return current }
            return PowerReading(c * alpha + p * (1 - alpha), source: current.source)
        }
        var result = new
        result.adapter = blend(new.adapter, previous.adapter)
        result.battery = blend(new.battery, previous.battery)
        result.system = blend(new.system, previous.system)
        return result
    }

    static func valid(_ value: Double, in range: ClosedRange<Double>) -> Double? {
        value.isFinite && range.contains(value) ? value : nil
    }
    private static func direction(_ power: Double?) -> Int {
        guard let power else { return 0 }
        return power > 0.2 ? 1 : (power < -0.2 ? -1 : 0)
    }
    private static func power(_ value: Int64?, signed: Bool = false) -> PowerReading {
        guard let value, value >= (signed ? -250_000 : 0), value <= 250_000 else { return .unavailable }
        return PowerReading(Double(value) / 1_000)
    }
    private static func calculated(_ value: Double, signed: Bool = false) -> PowerReading {
        guard let watts = valid(value, in: (signed ? -250 : 0)...250) else { return .unavailable }
        return PowerReading(watts, source: .calculated)
    }
    private static func voltagePower(_ voltage: Int64?, _ current: Int64?, signed: Bool = false) -> PowerReading {
        guard let voltage, let current, voltage >= 0, voltage <= 60_000,
              voltage > 0 || current == 0,
              current >= (signed ? -30_000 : 0), current <= 30_000 else { return .unavailable }
        return calculated(Double(voltage) * Double(current) / 1_000_000, signed: signed)
    }
}

enum ReadingFormat {
    static func watts(_ value: Double?, signed: Bool = false) -> String {
        guard let value else { return "—" }
        if signed && abs(value) <= 0.2 { return "Idle" }
        let prefix = signed ? (value > 0 ? "+" : "−") : ""
        return String(format: "%@%.1f W", prefix, abs(value))
    }
}
