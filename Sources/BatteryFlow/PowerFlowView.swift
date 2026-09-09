import AppKit
import SwiftUI

struct PowerFlowView: View {
    @ObservedObject var monitor: PowerMonitor
    @ObservedObject var preferences: AppPreferences
    @ObservedObject var history: HistoryStore
    var openSettings: () -> Void
    @State private var historyExpanded = false
    @State private var panelVisible = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var availableHeight: CGFloat { max(400, (NSScreen.main?.visibleFrame.height ?? 850) - 55) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                PowerFlowDiagram(snapshot: monitor.snapshot,
                    isAnimating: panelVisible && preferences.animationsEnabled && !monitor.isLowPowerMode && monitor.snapshot.canAnimate)
                    .frame(height: 212)
                metrics
                healthRow
                Divider()
                Button {
                    if reduceMotion { historyExpanded.toggle() }
                    else { withAnimation(.easeInOut(duration: 0.2)) { historyExpanded.toggle() } }
                } label: {
                    HStack {
                        Label("History", systemImage: "chart.xyaxis.line").font(AppTypography.section)
                        Spacer()
                        Text(preferences.recordingEnabled ? "\(preferences.retentionDays) \(preferences.retentionDays == 1 ? "day" : "days")" : "Paused")
                            .font(AppTypography.secondary).foregroundStyle(.secondary)
                        Image(systemName: historyExpanded ? "chevron.up" : "chevron.down")
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityValue(historyExpanded ? "Expanded" : "Collapsed")
                if historyExpanded {
                    HistoryChartView(store: history, preferences: preferences)
                }
                if let error = monitor.snapshot.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(AppTypography.secondary).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
                if let error = history.errorMessage {
                    HStack(alignment: .top) {
                        Label("History not saved: \(error)", systemImage: "exclamationmark.triangle")
                            .font(AppTypography.secondary).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                        Button("Retry") { Task { await history.retry() } }
                    }
                }
                if let warning = history.recoveryWarning {
                    Text(warning).font(AppTypography.secondary).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                footer
                Divider()
                HStack {
                    Button("Settings…", action: openSettings)
                        .keyboardShortcut(",", modifiers: .command)
                    Spacer()
                    Text("Charging is managed by macOS").font(AppTypography.secondary).foregroundStyle(.secondary)
                    Button("Quit") { monitor.stop(); NSApplication.shared.terminate(nil) }
                }
                .buttonStyle(.borderless)
            }
            .padding(16)
        }
        .frame(width: 520, height: min(historyExpanded ? 785 : 580, availableHeight))
        .font(AppTypography.body)
        .preferredColorScheme(preferences.appearance.colorScheme)
        .onAppear { panelVisible = true; monitor.setPanelVisible(true) }
        .onDisappear { panelVisible = false; monitor.setPanelVisible(false); historyExpanded = false }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Label(monitor.snapshot.state.title, systemImage: monitor.snapshot.state == .onBattery
                      ? monitor.snapshot.batteryIcon : monitor.snapshot.state.icon).font(AppTypography.section)
                Spacer()
                Text(monitor.snapshot.chargeText).font(AppTypography.reading)
                    .foregroundStyle(monitor.snapshot.isStale ? .secondary : .primary)
            }
            Text(monitor.snapshot.isStale ? "Showing the last known charge. Live power readings are unavailable."
                 : monitor.snapshot.state.detail)
                .font(AppTypography.secondary).foregroundStyle(.secondary)
        }
    }
    private var metrics: some View {
        HStack(spacing: 10) {
            MetricBox(label: "Mac", value: ReadingFormat.watts(monitor.snapshot.systemPowerWatts), systemImage: "laptopcomputer")
            MetricBox(label: "Battery", value: ReadingFormat.watts(monitor.snapshot.batteryPowerWatts, signed: true), systemImage: monitor.snapshot.batteryIcon)
            MetricBox(label: "Temperature", value: preferences.temperatureUnit.format(monitor.snapshot.isStale ? nil : monitor.snapshot.temperatureCelsius),
                      systemImage: "thermometer.medium")
        }
    }
    private var healthRow: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: monitor.health.needsService ? "exclamationmark.triangle.fill" : "heart")
                .foregroundStyle(monitor.health.needsService ? Color.orange : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(monitor.health.title).font(AppTypography.section)
                Text(monitor.health.capacityText + (monitor.health.cycleCount.map { " · \($0.formatted()) cycles" } ?? ""))
                    .font(AppTypography.secondary).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Battery Settings") { SystemSettings.openBattery() }.font(AppTypography.body).buttonStyle(.borderless)
        }
    }
    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                if let hardware = monitor.snapshot.hardwarePercent {
                    Text("Raw charge \(hardware, specifier: "%.1f")%")
                }
                Spacer(minLength: 12)
                if let timestamp = monitor.snapshot.isAwaitingPowerData
                    ? monitor.snapshot.powerUpdatedAt : (monitor.snapshot.powerUpdatedAt ?? monitor.snapshot.timestamp) {
                    Text(monitor.snapshot.isStale || monitor.snapshot.isAwaitingPowerData ? "Last power reading" : "Power updated")
                    Text(timestamp, style: .time)
                }
            }
            if monitor.snapshot.quality == .partial && !monitor.snapshot.isStale && !monitor.snapshot.isAwaitingPowerData {
                Text("Some power readings are unavailable.")
            } else if monitor.snapshot.isCalculated {
                Text("Power includes calculated readings.")
            }
        }
        .font(AppTypography.secondary).foregroundStyle(.secondary)
    }
}

private struct MetricBox: View {
    let label: String
    let value: String
    let systemImage: String
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(label, systemImage: systemImage).font(AppTypography.body).foregroundStyle(.secondary)
            Text(value).font(AppTypography.reading).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(10)
        .background(.quaternary.opacity(0.7), in: RoundedRectangle(cornerRadius: 10))
    }
}
