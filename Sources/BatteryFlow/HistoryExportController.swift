import AppKit
import Combine
import UniformTypeIdentifiers

@MainActor
final class HistoryExportController: ObservableObject {
    @Published private(set) var isExporting = false
    private var panel: NSSavePanel?

    func export(_ points: [HistoryPoint], range: HistoryRange) {
        guard !isExporting, !points.isEmpty else { return }
        isExporting = true
        let panel = NSSavePanel()
        self.panel = panel
        panel.title = "Export History"
        panel.message = "Export all recorded observations in the selected \(range.rawValue) range. Times use UTC; temperature uses Celsius."
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "BatteryFlow-\(range.rawValue)-\(Date().formatted(.iso8601.year().month().day().dateSeparator(.dash))).csv"
        panel.canCreateDirectories = true
        NSApp.activate(ignoringOtherApps: true)
        // A standalone save panel survives dismissal of the menu-bar popover.
        // Its completion retains this controller and the immutable export snapshot.
        panel.begin { [self] response in
            guard response == .OK, let url = panel.url else {
                isExporting = false
                self.panel = nil
                return
            }
            Task { [self] in
                do {
                    try await Task.detached(priority: .userInitiated) {
                        try HistoryCSV.encode(points).write(to: url, options: .atomic)
                    }.value
                } catch {
                    let alert = NSAlert()
                    alert.messageText = "History could not be exported"
                    alert.informativeText = error.localizedDescription
                    alert.runModal()
                }
                isExporting = false
                self.panel = nil
            }
        }
    }
}
