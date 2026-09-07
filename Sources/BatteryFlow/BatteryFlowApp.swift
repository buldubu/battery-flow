import AppKit
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    let preferences: AppPreferences
    let monitor: PowerMonitor
    let history: HistoryStore
    let loginController: LaunchAtLoginController
    lazy var settings = SettingsWindowController(model: self)

    init() {
        preferences = AppPreferences()
        history = HistoryStore(preferences: preferences)
        monitor = PowerMonitor(history: history, preferences: preferences)
        loginController = LaunchAtLoginController()
        AppDelegate.model = self
        monitor.start()
    }
}

@main
struct BatteryFlowApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()
    var body: some Scene {
        MenuBarExtra {
            PowerFlowView(monitor: model.monitor, preferences: model.preferences, history: model.history,
                          openSettings: { model.settings.show() })
        } label: {
            BatteryMenuLabel(monitor: model.monitor, preferences: model.preferences)
        }
        .menuBarExtraStyle(.window)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { model.settings.show() }
                    .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var model: AppModel?
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Self.model?.settings.show()
        return true
    }
    func applicationWillTerminate(_ notification: Notification) { Self.model?.monitor.stop() }
}
