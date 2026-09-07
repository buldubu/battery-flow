import Charts
import SwiftUI

struct HistoryChartView: View {
    @ObservedObject var store: HistoryStore
    @ObservedObject var preferences: AppPreferences

    var body: some View {
        let data = store.chartSamples(in: preferences.historyRange)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Picker("Metric", selection: $preferences.historyMetric) {
                    ForEach(HistoryMetric.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden().pickerStyle(.segmented)
                Picker("Range", selection: $preferences.historyRange) {
                    ForEach(preferences.availableRanges) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden().pickerStyle(.segmented)
            }
            if store.isLoading {
                ProgressView("Loading history…").frame(maxWidth: .infinity, minHeight: 155)
            } else if data.isEmpty {
                VStack(spacing: 5) {
                    Image(systemName: "chart.xyaxis.line").font(.title2)
                    Text(preferences.recordingEnabled ? "Collecting history" : "History recording is paused")
                    Text("A new observation is stored every minute while recording.")
                        .font(AppTypography.secondary).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 155)
            } else {
                if preferences.historyMetric == .power {
                    HStack(spacing: 12) {
                        legend("Adapter", color: .blue)
                        legend("Mac", color: .purple)
                        legend("Battery", color: .orange)
                    }
                    .font(AppTypography.secondary)
                }
                chart(data)
                    .chartXAxis {
                        AxisMarks(values: .automatic(desiredCount: 4)) {
                            AxisGridLine()
                            AxisTick()
                            AxisValueLabel().font(AppTypography.secondary)
                        }
                    }
                    .chartYAxis {
                        AxisMarks(values: .automatic(desiredCount: 4)) {
                            AxisGridLine()
                            AxisTick()
                            AxisValueLabel().font(AppTypography.secondary)
                        }
                    }
                    .frame(height: 165)
            }
            if store.excludedPowerCount > 0 && preferences.historyMetric == .power {
                Text("Inconsistent power readings are excluded. Gaps indicate missing observations.")
                    .font(AppTypography.secondary).foregroundStyle(.secondary)
            }
        }
        .font(AppTypography.body)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Historical \(preferences.historyMetric.rawValue.lowercased()) graph for \(preferences.historyRange.rawValue)")
    }

    private func legend(_ title: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6).accessibilityHidden(true)
            Text(title).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func chart(_ data: [ChartSample]) -> some View {
        switch preferences.historyMetric {
        case .power:
            Chart {
                ForEach(data) { point in
                    if let value = point.adapter {
                        LineMark(x: .value("Time", point.timestamp), y: .value("Watts", value),
                                 series: .value("Segment", "Adapter-\(point.powerSegment)"))
                            .foregroundStyle(by: .value("Flow", "Adapter")).interpolationMethod(.linear)
                    }
                    if let value = point.system {
                        LineMark(x: .value("Time", point.timestamp), y: .value("Watts", value),
                                 series: .value("Segment", "Mac-\(point.powerSegment)"))
                            .foregroundStyle(by: .value("Flow", "Mac")).interpolationMethod(.linear)
                    }
                    if let value = point.battery {
                        LineMark(x: .value("Time", point.timestamp), y: .value("Watts", value),
                                 series: .value("Segment", "Battery-\(point.powerSegment)"))
                            .foregroundStyle(by: .value("Flow", "Battery")).interpolationMethod(.linear)
                    }
                }
                RuleMark(y: .value("Zero", 0)).foregroundStyle(.secondary.opacity(0.35))
            }
            .chartForegroundStyleScale(["Adapter": Color.blue, "Mac": Color.purple, "Battery": Color.orange])
            .chartYAxisLabel { Text("W").font(AppTypography.secondary) }
            .chartLegend(.hidden)
        case .charge:
            Chart(data) { point in
                if let value = point.charge {
                    LineMark(x: .value("Time", point.timestamp), y: .value("Charge", value),
                             series: .value("Segment", point.segment.uuidString))
                        .foregroundStyle(.green).interpolationMethod(.linear)
                }
            }
            .chartYScale(domain: 0...100)
            .chartYAxisLabel { Text("%").font(AppTypography.secondary) }.chartLegend(.hidden)
        case .temperature:
            Chart(data) { point in
                if let value = point.temperature {
                    LineMark(x: .value("Time", point.timestamp), y: .value("Temperature", preferences.temperatureUnit.convert(value)),
                             series: .value("Segment", point.segment.uuidString))
                        .foregroundStyle(.red).interpolationMethod(.linear)
                }
            }
            .chartYAxisLabel { Text(preferences.temperatureUnit.symbol).font(AppTypography.secondary) }.chartLegend(.hidden)
        }
    }
}
