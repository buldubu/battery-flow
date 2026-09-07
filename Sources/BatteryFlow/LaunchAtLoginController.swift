import Foundation
import ServiceManagement
import SwiftUI

enum LoginStatus { case enabled, notRegistered, requiresApproval, notFound, unknown }

@MainActor
protocol LoginServicing {
    var status: LoginStatus { get }
    var available: Bool { get }
    func register() throws
    func unregister() throws
    func openSettings()
}

@MainActor
struct SystemLoginService: LoginServicing {
    var available: Bool { Bundle.main.bundleURL.standardizedFileURL.path == "/Applications/BatteryFlow.app" }
    var status: LoginStatus {
        switch SMAppService.mainApp.status {
        case .enabled: .enabled
        case .notRegistered: .notRegistered
        case .requiresApproval: .requiresApproval
        case .notFound: .notFound
        @unknown default: .unknown
        }
    }
    func register() throws { try SMAppService.mainApp.register() }
    func unregister() throws { try SMAppService.mainApp.unregister() }
    func openSettings() { SMAppService.openSystemSettingsLoginItems() }
}

@MainActor
final class LaunchAtLoginController: ObservableObject {
    @Published private(set) var isEnabled = false
    @Published private(set) var status: LoginStatus = .notRegistered
    @Published private(set) var errorMessage: String?
    private let service: any LoginServicing

    var isAvailable: Bool { service.available }
    var statusMessage: String? {
        if !isAvailable { return "Launch at login is available after installation in Applications." }
        switch status {
        case .enabled, .notRegistered: return nil
        case .requiresApproval: return "Allow Battery Flow in System Settings → General → Login Items."
        case .notFound: return "macOS could not find the installed application."
        case .unknown: return "macOS returned an unknown login-item status."
        }
    }

    init(service: any LoginServicing = SystemLoginService()) {
        self.service = service
        // Registration is exclusively user-driven. Never restore an old desired preference over macOS.
        refresh()
    }
    func setEnabled(_ enabled: Bool) {
        guard isAvailable else { return }
        do {
            if enabled && service.status != .enabled { try service.register() }
            else if !enabled && service.status != .notRegistered { try service.unregister() }
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
        refresh()
    }
    func refresh() {
        status = service.status
        isEnabled = isAvailable && status == .enabled
    }
    func openSettings() { service.openSettings() }
}
