import Charts
import SwiftUI

struct HistoryChartView: View {
    @ObservedObject var store: HistoryStore
    @ObservedObject var preferences: AppPreferences
    @State private var selectedID: UUID?
    @StateObject private var exporter = HistoryExportController()

    var body: some View {
        let data = store.chartSamples(in: preferences.historyRange)
        let samples = data.filter(hasMeasurement)
        let selected = samples.first { $0.id == selectedID }
        let summary = store.summary(in: preferences.historyRange)
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
            } else if samples.isEmpty {
                VStack(spacing: 5) {
                    Image(systemName: "chart.xyaxis.line").font(.title2)
                    Text(data.isEmpty ? (preferences.recordingEnabled ? "Collecting history" : "History recording is paused")
                         : "No \(preferences.historyMetric.rawValue.lowercased()) readings in this range")
                    Text(data.isEmpty ? "A new observation is stored every minute while recording."
                         : "macOS may not report this measurement. Other recorded values can still be exported.")
                        .font(AppTypography.secondary).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 155)
            } else {
                if preferences.historyMetric == .power {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 12) {
                            legend("Adapter", color: .blue)
                            legend("Mac", color: .purple)
                            legend("Battery (− charging / + discharging)", color: .orange)
                        }
                        Text("Above zero: supplying · Below zero: consuming")
                            .foregroundStyle(.secondary)
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
                    .chartOverlay { proxy in
                        inspectionOverlay(proxy: proxy, samples: samples, selected: selected)
                    }
                    .frame(height: 165)
                    .focusable()
                    .onMoveCommand { direction in
                        if direction == .left { moveSelection(-1, in: samples) }
                        if direction == .right { moveSelection(1, in: samples) }
                    }
                    .onExitCommand { selectedID = nil }
                    .accessibilityHint("Use the left and right arrow keys to inspect recorded readings.")
                inspection(selected, samples: samples)
            }
            HStack(alignment: .top) {
                Text(summaryText(summary))
                    .font(AppTypography.secondary).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button(exporter.isExporting ? "Exporting…" : "Export CSV…") {
                    exporter.export(store.observations(in: preferences.historyRange), range: preferences.historyRange)
                }
                .disabled(store.isLoading || summary.count == 0 || exporter.isExporting)
                .help("Export every recorded observation in the selected range, including all measurements and quality flags.")
            }
            if store.excludedPowerCount > 0 && preferences.historyMetric == .power {
                Text("Inconsistent power readings are excluded. Gaps indicate missing observations.")
                    .font(AppTypography.secondary).foregroundStyle(.secondary)
            }
        }
        .font(AppTypography.body)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Historical \(preferences.historyMetric.rawValue.lowercased()) graph for \(preferences.historyRange.rawValue)")
        .onChange(of: preferences.historyRange) { _ in selectedID = nil }
        .onChange(of: preferences.historyMetric) { _ in selectedID = nil }
    }

    private func hasMeasurement(_ sample: ChartSample) -> Bool {
        switch preferences.historyMetric {
        case .power: sample.adapter != nil || sample.system != nil || sample.battery != nil
        case .charge: sample.charge != nil
        case .temperature: sample.temperature != nil
        }
    }

    private func inspectionOverlay(proxy: ChartProxy, samples: [ChartSample], selected: ChartSample?) -> some View {
        GeometryReader { geometry in
            let frame = geometry[proxy.plotAreaFrame]
            ZStack(alignment: .topLeading) {
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        if case let .active(location) = phase {
                            select(at: location, proxy: proxy, frame: frame, samples: samples)
                        }
                    }
                    .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                        select(at: value.location, proxy: proxy, frame: frame, samples: samples)
                    })
                if let selected, let x = proxy.position(forX: selected.timestamp) {
                    Rectangle().fill(Color.secondary.opacity(0.65))
                        .frame(width: 1, height: frame.height)
                        .position(x: frame.minX + x, y: frame.midY)
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
            }
        }
    }

    private func select(at location: CGPoint, proxy: ChartProxy, frame: CGRect, samples: [ChartSample]) {
        guard frame.contains(location), let date = proxy.value(atX: location.x - frame.minX, as: Date.self) else { return }
        selectedID = HistoryAnalysis.nearest(to: date, in: samples)?.id
    }

    private func moveSelection(_ offset: Int, in samples: [ChartSample]) {
        guard !samples.isEmpty else { return }
        if let index = samples.firstIndex(where: { $0.id == selectedID }) {
            selectedID = samples[min(max(index + offset, 0), samples.count - 1)].id
        } else {
            selectedID = offset > 0 ? samples.first?.id : samples.last?.id
        }
    }

    private func inspection(_ selected: ChartSample?, samples: [ChartSample]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                if let selected {
                    Text(selected.timestamp.formatted(.dateTime.month(.abbreviated).day().hour().minute()))
                    if selected.observationCount > 1 {
                        Text("– \(selected.endTimestamp.formatted(.dateTime.hour().minute())) · \(selected.observationCount) readings averaged")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("Hover, drag, or use arrow keys to inspect.").foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Button { moveSelection(-1, in: samples) } label: { Image(systemName: "chevron.left") }
                    .help("Previous reading").accessibilityLabel("Previous history reading")
                Button { moveSelection(1, in: samples) } label: { Image(systemName: "chevron.right") }
                    .help("Next reading").accessibilityLabel("Next history reading")
            }
            .buttonStyle(.borderless)
            if let selected {
                switch preferences.historyMetric {
                case .power:
                    let flow = HistoryPowerFlow(adapter: selected.adapter, system: selected.system, battery: selected.battery)
                    HStack(spacing: 12) {
                        Text("Adapter \(ReadingFormat.watts(selected.adapter))").foregroundStyle(.blue)
                        Text("Mac using \(ReadingFormat.watts(selected.system))").foregroundStyle(.purple)
                        Text("Battery \(flow.batteryLabel)").foregroundStyle(.orange)
                    }
                case .charge: Text("Charge \(decimal(selected.charge))%")
                case .temperature: Text("Temperature \(preferences.temperatureUnit.format(selected.temperature))")
                }
            } else {
                Text("Readings follow recorded times; gaps have no observations.").foregroundStyle(.secondary)
            }
        }
        .font(AppTypography.secondary).monospacedDigit()
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
    }

    private func decimal(_ value: Double?) -> String {
        value.map { $0.formatted(.number.precision(.fractionLength(1))) } ?? "—"
    }

    private func summaryText(_ summary: HistorySummary) -> String {
        let values: MetricStatistics
        let label: String
        switch preferences.historyMetric {
        case .power: values = summary.mac; label = "Mac"
        case .charge: values = summary.charge; label = "Charge"
        case .temperature: values = summary.temperature; label = "Temperature"
        }
        func format(_ value: Double?) -> String {
            switch preferences.historyMetric {
            case .power: ReadingFormat.watts(value)
            case .charge: value == nil ? "—" : decimal(value) + "%"
            case .temperature: preferences.temperatureUnit.format(value)
            }
        }
        return "\(summary.count.formatted()) observations · \(label) average \(format(values.average)) · peak \(format(values.peak))"
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
                    let flow = HistoryPowerFlow(adapter: point.adapter, system: point.system, battery: point.battery)
                    if let value = flow.adapter {
                        LineMark(x: .value("Time", point.timestamp), y: .value("Watts", value),
                                 series: .value("Segment", "Adapter-\(point.powerSegment)"))
                            .foregroundStyle(by: .value("Flow", "Adapter")).interpolationMethod(.linear)
                    }
                    if let value = flow.mac {
                        LineMark(x: .value("Time", point.timestamp), y: .value("Watts", value),
                                 series: .value("Segment", "Mac-\(point.powerSegment)"))
                            .foregroundStyle(by: .value("Flow", "Mac")).interpolationMethod(.linear)
                    }
                    if let value = flow.battery {
                        LineMark(x: .value("Time", point.timestamp), y: .value("Watts", value),
                                 series: .value("Segment", "Battery-\(point.powerSegment)"))
                            .foregroundStyle(by: .value("Flow", "Battery")).interpolationMethod(.linear)
                    }
                }
                RuleMark(y: .value("Zero", 0)).foregroundStyle(.secondary.opacity(0.65))
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
