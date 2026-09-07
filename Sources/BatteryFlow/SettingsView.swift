import AppKit
import SwiftUI
import Combine

enum SettingsTab: Hashable { case general, history, battery }

@MainActor
final class SettingsWindowController: NSObject, ObservableObject, NSWindowDelegate {
    @Published var selectedTab: SettingsTab = .general
    private let model: AppModel
    private var controller: NSWindowController?
    private var appearanceSubscription: AnyCancellable?

    init(model: AppModel) {
        self.model = model
        super.init()
        appearanceSubscription = model.preferences.$appearance.sink { [weak self] appearance in
            self?.controller?.window?.appearance = Self.appearance(appearance)
        }
    }
    func show(tab: SettingsTab? = nil) {
        if let tab { selectedTab = tab }
        if controller == nil {
            let host = NSHostingController(rootView: SettingsView(model: model, coordinator: self))
            let window = NSWindow(contentViewController: host)
            window.title = "Battery Flow Settings"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.setContentSize(NSSize(width: 600, height: 580))
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.appearance = Self.appearance(model.preferences.appearance)
            window.center()
            controller = NSWindowController(window: window)
        }
        model.loginController.refresh()
        NSApp.activate(ignoringOtherApps: true)
        controller?.showWindow(nil)
        controller?.window?.makeKeyAndOrderFront(nil)
    }
    func windowDidBecomeKey(_ notification: Notification) { model.loginController.refresh() }
    private static func appearance(_ preference: AppAppearance) -> NSAppearance? {
        switch preference {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

@MainActor
enum SystemSettings {
    static func openBattery() {
        let url = URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension")!
        if !NSWorkspace.shared.open(url) {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
        }
    }
}

private struct SettingsView: View {
    let model: AppModel
    @ObservedObject var coordinator: SettingsWindowController
    @ObservedObject private var preferences: AppPreferences

    init(model: AppModel, coordinator: SettingsWindowController) {
        self.model = model
        self.coordinator = coordinator
        preferences = model.preferences
    }
    var body: some View {
        TabView(selection: $coordinator.selectedTab) {
            GeneralSettings(preferences: preferences, login: model.loginController)
                .tabItem { Label("General", systemImage: "gearshape") }.tag(SettingsTab.general)
            HistorySettings(preferences: preferences, history: model.history)
                .tabItem { Label("History", systemImage: "chart.xyaxis.line") }.tag(SettingsTab.history)
            BatterySettings(monitor: model.monitor)
                .tabItem { Label("Battery", systemImage: "battery.75percent") }.tag(SettingsTab.battery)
        }
        .padding(16)
        .frame(width: 600, height: 580)
        .font(AppTypography.body)
        .preferredColorScheme(preferences.appearance.colorScheme)
        .background {
            Button("Settings…") { coordinator.show() }
                .keyboardShortcut(",", modifiers: .command).hidden()
        }
    }
}

private struct GeneralSettings: View {
    @ObservedObject var preferences: AppPreferences
    @ObservedObject var login: LaunchAtLoginController
    private var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return "\(info["CFBundleShortVersionString"] as? String ?? "Development") (\(info["CFBundleVersion"] as? String ?? "—"))"
    }
    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Launch at login", isOn: Binding(get: { login.isEnabled }, set: { login.setEnabled($0) }))
                    .disabled(!login.isAvailable)
                if let status = login.statusMessage {
                    Text(status).font(AppTypography.secondary).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if let error = login.errorMessage {
                    Text(error).font(AppTypography.secondary).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
                if login.status == .requiresApproval || login.errorMessage != nil {
                    Button("Open Login Items") { login.openSettings() }
                }
            }
            Section("Display") {
                Picker("Appearance", selection: $preferences.appearance) {
                    ForEach(AppAppearance.allCases) { Text($0.rawValue).tag($0) }
                }
                Toggle("Show percentage in menu bar", isOn: $preferences.showPercentage)
                Picker("Temperature", selection: $preferences.temperatureUnit) {
                    ForEach(TemperatureUnit.allCases) { Text("\($0.rawValue) (\($0.symbol))").tag($0) }
                }
            }
            Section("Motion") {
                Toggle("Animate power flow", isOn: $preferences.animationsEnabled)
                Text("Animation pauses in Low Power Mode and when Reduce Motion is enabled.")
                    .font(AppTypography.secondary).foregroundStyle(.secondary)
            }
            Section {
                SettingsReadout("Battery Flow", value: version)
                    .font(AppTypography.secondary).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct HistorySettings: View {
    @ObservedObject var preferences: AppPreferences
    @ObservedObject var history: HistoryStore
    @State private var showClearConfirmation = false
    @State private var pendingRetention: Int?
    @State private var showRetentionConfirmation = false
    @State private var busy = false

    var body: some View {
        Form {
            Section("Recording") {
                Toggle("Record history", isOn: $preferences.recordingEnabled)
                Text(preferences.recordingEnabled ? "One observation per minute while your Mac is awake."
                     : "Recording is paused. Existing history remains available within the retention period.")
                    .font(AppTypography.secondary).foregroundStyle(.secondary)
                Picker("Keep history for", selection: Binding(get: { preferences.retentionDays }, set: { requestRetention($0) })) {
                    Text("1 day").tag(1)
                    Text("7 days").tag(7)
                    Text("30 days").tag(30)
                }
                .disabled(busy || history.isLoading)
            }
            Section("Local history") {
                SettingsReadout("Retained samples", value: history.isLoading ? "Loading…" : history.points.count.formatted())
                if history.pendingCount > 0 {
                    SettingsReadout("Waiting to save", value: history.pendingCount.formatted())
                }
                if history.excludedPowerCount > 0 {
                    Text("\(history.excludedPowerCount) samples have inconsistent power values and are excluded from power graphs. Their other measurements are preserved.")
                        .font(AppTypography.secondary).foregroundStyle(.secondary)
                }
                if let error = history.errorMessage {
                    Label("History could not be saved: \(error)", systemImage: "exclamationmark.triangle")
                        .font(AppTypography.secondary).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                    Button("Retry Saving") { Task { await history.retry() } }
                }
                if let warning = history.recoveryWarning {
                    Text(warning).font(AppTypography.secondary).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Button("Clear History…", role: .destructive) { showClearConfirmation = true }
                    .disabled(busy || history.isLoading)
                Text("History stays on this Mac. Recovery copies, if any, are separate files in Application Support/BatteryFlow.")
                    .font(AppTypography.secondary).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Clear recorded history?", isPresented: $showClearConfirmation, titleVisibility: .visible) {
            Button("Clear History", role: .destructive) {
                Task { busy = true; await history.clear(); busy = false }
            }
        } message: {
            Text("This removes all retained and unsaved samples from the active history. Recording will continue if enabled. Separate recovery copies are kept.")
        }
        .confirmationDialog("Shorten history retention?", isPresented: $showRetentionConfirmation, titleVisibility: .visible) {
            Button("Remove Older Samples", role: .destructive) {
                if let days = pendingRetention { preferences.setRetentionDays(days) }
                pendingRetention = nil
            }
            Button("Cancel", role: .cancel) { pendingRetention = nil }
        } message: {
            Text("This removes \(history.countOlder(than: pendingRetention ?? preferences.retentionDays)) samples older than \(pendingRetention ?? preferences.retentionDays) \((pendingRetention ?? preferences.retentionDays) == 1 ? "day" : "days").")
        }
    }
    private func requestRetention(_ days: Int) {
        if days < preferences.retentionDays && history.countOlder(than: days) > 0 {
            pendingRetention = days
            showRetentionConfirmation = true
        } else { preferences.setRetentionDays(days) }
    }
}

private struct BatterySettings: View {
    @ObservedObject var monitor: PowerMonitor
    var body: some View {
        Form {
            Section("Battery health") {
                SettingsReadout("Condition", value: monitor.health.title)
                    .foregroundStyle(monitor.health.needsService ? Color.orange : Color.primary)
                SettingsReadout("Maximum capacity", value: monitor.health.maximumCapacityPercent.map { "\($0)%" } ?? "Unavailable")
                SettingsReadout("Cycle count", value: monitor.health.cycleCount.map { $0.formatted() } ?? "Unavailable")
                if let date = monitor.health.displayedConditionUpdatedAt {
                    SettingsReadout("Condition checked", value: date.formatted(.dateTime.year().month().day().hour().minute()))
                }
                if let date = monitor.health.capacityUpdatedAt {
                    SettingsReadout("Capacity checked", value: date.formatted(.dateTime.year().month().day().hour().minute()))
                }
                if let error = monitor.health.errorMessage {
                    Text("\(error) Cached health values retain the dates of their last successful readings.")
                        .font(AppTypography.secondary).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Button(monitor.isRefreshingHealth ? "Refreshing…" : "Refresh Health") { monitor.refreshHealth(force: true) }
                    .disabled(monitor.isRefreshingHealth)
                Text("Condition and maximum capacity are reported by macOS. Maximum capacity is refreshed at most hourly, or when you refresh it.")
                    .font(AppTypography.secondary).foregroundStyle(.secondary)
            }
            Section("Charging and energy") {
                if let rating = monitor.snapshot.adapterRatingWatts, monitor.snapshot.externalConnected == true {
                    SettingsReadout("Adapter rating", value: ReadingFormat.watts(rating))
                    Text("Rated capacity is different from the power currently being used.")
                        .font(AppTypography.secondary).foregroundStyle(.secondary)
                }
                Button("Open Battery Settings") { SystemSettings.openBattery() }
                Text("Change the charge limit, Optimized Battery Charging, and Low Power Mode in macOS Battery settings. Available options depend on your Mac and macOS version.")
                    .font(AppTypography.secondary).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// Keep each label attached to its value when VoiceOver traverses adjacent form rows.
private struct SettingsReadout: View {
    let label: String
    let value: String
    init(_ label: String, value: String) { self.label = label; self.value = value }
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(AppTypography.body)
            Spacer(minLength: 12)
            Text(value).font(AppTypography.body).multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): \(value)")
        .accessibilityAddTraits(.isStaticText)
    }
}
