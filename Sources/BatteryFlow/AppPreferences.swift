import Foundation
import SwiftUI

enum AppAppearance: String, CaseIterable, Identifiable {
    case system = "System", light = "Light", dark = "Dark"
    var id: Self { self }
    var colorScheme: ColorScheme? { self == .system ? nil : (self == .light ? .light : .dark) }
}
enum TemperatureUnit: String, CaseIterable, Identifiable {
    case celsius = "Celsius", fahrenheit = "Fahrenheit"
    var id: Self { self }
    var symbol: String { self == .celsius ? "°C" : "°F" }
    func convert(_ celsius: Double) -> Double { self == .celsius ? celsius : celsius * 9 / 5 + 32 }
    func format(_ celsius: Double?) -> String {
        guard let celsius else { return "—" }
        return String(format: "%.1f %@", convert(celsius), symbol)
    }
}
enum HistoryMetric: String, CaseIterable, Identifiable {
    case power = "Power", charge = "Charge", temperature = "Temp"
    var id: Self { self }
}
enum HistoryRange: String, CaseIterable, Identifiable, Sendable {
    case hour = "1H", day = "24H", week = "7D", month = "30D"
    var id: Self { self }
    var duration: TimeInterval {
        switch self { case .hour: 3600; case .day: 86400; case .week: 7 * 86400; case .month: 30 * 86400 }
    }
}

@MainActor
final class AppPreferences: ObservableObject {
    private let defaults: UserDefaults
    @Published var appearance: AppAppearance { didSet { defaults.set(appearance.rawValue, forKey: "appearance") } }
    @Published var showPercentage: Bool { didSet { defaults.set(showPercentage, forKey: "showPercentage") } }
    @Published var temperatureUnit: TemperatureUnit { didSet { defaults.set(temperatureUnit.rawValue, forKey: "temperatureUnit") } }
    @Published var animationsEnabled: Bool { didSet { defaults.set(animationsEnabled, forKey: "animationsEnabled") } }
    @Published var recordingEnabled: Bool { didSet { defaults.set(recordingEnabled, forKey: "recordingEnabled") } }
    @Published private(set) var retentionDays: Int
    @Published var historyMetric: HistoryMetric { didSet { defaults.set(historyMetric.rawValue, forKey: "historyMetric") } }
    @Published var historyRange: HistoryRange { didSet { defaults.set(historyRange.rawValue, forKey: "historyRange") } }
    var availableRanges: [HistoryRange] { HistoryRange.allCases.filter { $0.duration <= Double(retentionDays) * 86400 } }

    var cachedHealth: BatteryHealthSnapshot? {
        get {
            guard let data = defaults.data(forKey: "cachedBatteryHealth") else { return nil }
            return try? JSONDecoder().decode(BatteryHealthSnapshot.self, from: data)
        }
        set { defaults.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: "cachedBatteryHealth") }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        appearance = AppAppearance(rawValue: defaults.string(forKey: "appearance") ?? "") ?? .system
        showPercentage = defaults.bool(forKey: "showPercentage")
        temperatureUnit = TemperatureUnit(rawValue: defaults.string(forKey: "temperatureUnit") ?? "") ?? .celsius
        animationsEnabled = defaults.object(forKey: "animationsEnabled") as? Bool ?? true
        recordingEnabled = defaults.object(forKey: "recordingEnabled") as? Bool ?? true
        let days = defaults.integer(forKey: "retentionDays")
        let validatedDays = [1, 7, 30].contains(days) ? days : 30
        retentionDays = validatedDays
        historyMetric = HistoryMetric(rawValue: defaults.string(forKey: "historyMetric") ?? "") ?? .power
        let range = HistoryRange(rawValue: defaults.string(forKey: "historyRange") ?? "") ?? .day
        historyRange = range.duration <= Double(validatedDays) * 86400 ? range : .day
    }
    func setRetentionDays(_ days: Int) {
        guard [1, 7, 30].contains(days) else { return }
        retentionDays = days
        defaults.set(days, forKey: "retentionDays")
        if !availableRanges.contains(historyRange) { historyRange = .day }
    }
}
