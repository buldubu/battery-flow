import SwiftUI

struct BatteryMenuLabel: View {
    @ObservedObject var monitor: PowerMonitor
    @ObservedObject var preferences: AppPreferences
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: monitor.snapshot.state == .unavailable ? "questionmark.circle" : monitor.snapshot.batteryIcon)
            if monitor.snapshot.state == .paused && !monitor.snapshot.isStale {
                Image(systemName: "sailboat.fill")
            }
            if preferences.showPercentage {
                Text(monitor.snapshot.chargeText).monospacedDigit()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Battery Flow, \(monitor.snapshot.chargeText), \(monitor.snapshot.state.title)")
        .help("Battery Flow — \(monitor.snapshot.state.title), \(monitor.snapshot.chargeText)")
    }
}
