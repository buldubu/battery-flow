import AppKit
import SwiftUI
import Foundation

// This entry point is compiled only by ui-review.sh, never into the installed product.
enum ReviewScenario: String, CaseIterable, Identifiable, Sendable {
    case live = "This Mac"
    case charging = "Charging"
    case charged = "Fully charged"
    case paused = "Not charging"
    case supplementing = "Adapter + battery"
    case onBattery = "On battery"
    case inconsistent = "Inconsistent power"
    case stale = "Stale + long errors"
    case longHealth = "Long health label"
    var id: Self { self }
}

actor ReviewTelemetryReader: TelemetryReading {
    var scenario = ReviewScenario.live
    let live = BatteryTelemetryReader()
    func select(_ scenario: ReviewScenario) { self.scenario = scenario }
    func read() async throws -> RawPowerTelemetry {
        if scenario == .live { return try await live.read() }
        if scenario == .stale {
            throw HealthReadError.failed("The power source could not be read. This deliberately long review message checks that the last successful reading, recovery controls and footer remain readable when telemetry is temporarily unavailable.")
        }
        var raw = RawPowerTelemetry(chargePercent: 80, rawCurrentCapacity: 2400, rawMaxCapacity: 3000,
            rawTemperature: 3032, cycleCount: 1227, externalConnected: true, isCharging: false, isFullyCharged: false,
            adapterRatingWatts: 75, directAdapterPowerMilliwatts: 10000, directBatteryPowerMilliwatts: 0,
            directSystemLoadMilliwatts: 10000, healthCondition: "Check Battery", healthEstimate: "Poor")
        switch scenario {
        case .charging:
            raw.isCharging = true
            raw.directAdapterPowerMilliwatts = 30000
            raw.directBatteryPowerMilliwatts = 10000
            raw.directSystemLoadMilliwatts = 20000
        case .charged: raw.isFullyCharged = true; raw.chargePercent = 100
        case .supplementing:
            raw.directAdapterPowerMilliwatts = 15000
            raw.directBatteryPowerMilliwatts = -10000
            raw.directSystemLoadMilliwatts = 25000
        case .onBattery:
            raw.externalConnected = false
            raw.directAdapterPowerMilliwatts = 0
            raw.directBatteryPowerMilliwatts = -10000
        case .inconsistent: raw.directAdapterPowerMilliwatts = 75000
        case .longHealth:
            raw.healthCondition = "A deliberately long operating-system condition description used to review wrapping and accessibility"
            raw.healthEstimate = "Good"
        default: break
        }
        return raw
    }
}

actor ReviewHealthReader: HealthReading {
    var scenario = ReviewScenario.live
    func select(_ scenario: ReviewScenario) { self.scenario = scenario }
    func readHealth() async throws -> ProfiledBatteryHealth {
        if scenario == .live { return try await SystemProfilerHealthReader().readHealth() }
        if scenario == .stale {
            throw HealthReadError.failed("The detailed health refresh failed. This is a review fixture for a long subprocess error; any cached values must keep their dates and remain readable.")
        }
        return ProfiledBatteryHealth(maximumCapacityPercent: 71,
            condition: scenario == .longHealth
                ? "A deliberately long operating-system condition description used to review wrapping and accessibility"
                : "Check Battery", cycleCount: 1227)
    }
}

final class ReviewHistoryFiles: HistoryFileAccess, @unchecked Sendable {
    private let lock = NSLock()
    private var failWrites = false
    private let local = LocalHistoryFiles()
    func setFailure(_ failure: Bool) { lock.withLock { failWrites = failure } }
    private func check() throws {
        if lock.withLock({ failWrites }) {
            throw HealthReadError.failed("The history file could not be written because the review storage is temporarily unavailable. Pending observations are retained for retry. This deliberately long message checks wrapping beside the Retry button.")
        }
    }
    func read(_ url: URL) throws -> Data? { try local.read(url) }
    func append(_ data: Data, to url: URL) throws { try check(); try local.append(data, to: url) }
    func replace(_ data: Data, at url: URL) throws { try check(); try local.replace(data, at: url) }
    func backup(_ url: URL) throws -> URL { try local.backup(url) }
}

@MainActor
final class ReviewLoginService: LoginServicing {
    var status = LoginStatus.enabled
    var available = true
    var fail = false
    func register() throws {
        if fail { throw HealthReadError.failed("macOS requires approval before this login item can run. This review fixture deliberately includes a longer registration error to check that the explanation and Open Login Items button fit.") }
        status = .enabled
    }
    func unregister() throws { status = .notRegistered }
    func openSettings() { SystemLoginService().openSettings() }
}

@MainActor
final class AppModel: ObservableObject {
    static let preferenceDomain = "local.buldubu.BatteryFlow.UIReview.Preferences"
    @Published var scenario = ReviewScenario.live
    let preferences: AppPreferences
    let monitor: PowerMonitor
    let history: HistoryStore
    let loginController: LaunchAtLoginController
    lazy var settings = SettingsWindowController(model: self)
    private let reader = ReviewTelemetryReader()
    private let healthReader = ReviewHealthReader()
    private let files = ReviewHistoryFiles()
    private let login = ReviewLoginService()

    init() {
        let defaults = UserDefaults(suiteName: Self.preferenceDomain)!
        defaults.removePersistentDomain(forName: Self.preferenceDomain)
        preferences = AppPreferences(defaults: defaults)
        let historyURL = URL(fileURLWithPath: Bundle.main.infoDictionary!["BFReviewHistoryPath"] as! String)
        history = HistoryStore(preferences: preferences, fileURL: historyURL, files: files)
        monitor = PowerMonitor(history: history, reader: reader, healthReader: healthReader, preferences: preferences)
        loginController = LaunchAtLoginController(service: login)
        ReviewDelegate.model = self
        monitor.start(observeSystem: false)
    }
    func select(_ scenario: ReviewScenario) async {
        monitor.stop()
        await reader.select(scenario)
        await healthReader.select(scenario)
        files.setFailure(scenario == .stale)
        login.fail = scenario == .stale
        login.status = scenario == .stale ? .requiresApproval : .enabled
        loginController.setEnabled(true)
        await monitor.refresh()
        monitor.refreshHealth(force: true)
        if scenario == .stale {
            // The injected failure occurs before the copy can be cleared.
            await history.clear()
        } else {
            await history.retry()
            monitor.start(observeSystem: false)
        }
    }
}

@MainActor
final class ReviewDelegate: NSObject, NSApplicationDelegate {
    static weak var model: AppModel?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationWillTerminate(_ notification: Notification) {
        Self.model?.monitor.stop()
        UserDefaults.standard.removePersistentDomain(forName: AppModel.preferenceDomain)
    }
}

@main
struct BatteryFlowUIReviewApp: App {
    @NSApplicationDelegateAdaptor(ReviewDelegate.self) private var delegate
    @StateObject private var model = AppModel()
    var body: some Scene {
        WindowGroup("Battery Flow UI Review") {
            VStack(spacing: 0) {
                HStack {
                    BatteryMenuLabel(monitor: model.monitor, preferences: model.preferences)
                        .font(AppTypography.body)
                        .accessibilityLabel("Menu bar preview")
                    Spacer()
                    Picker("Scenario", selection: $model.scenario) {
                        ForEach(ReviewScenario.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .frame(width: 245)
                }
                .padding(12)
                .frame(width: 520)
                Divider()
                PowerFlowView(monitor: model.monitor, preferences: model.preferences, history: model.history,
                    openSettings: { model.settings.show() })
            }
            .preferredColorScheme(model.preferences.appearance.colorScheme)
            .onChange(of: model.scenario) { value in Task { await model.select(value) } }
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { model.settings.show() }.keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}
