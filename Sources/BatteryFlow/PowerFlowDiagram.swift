import SwiftUI

struct PowerFlowDiagram: View {
    let snapshot: PowerSnapshot
    let isAnimating: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let adapter = CGPoint(x: 62, y: 62)
            let mac = CGPoint(x: size.width - 62, y: 62)
            let battery = CGPoint(x: size.width / 2, y: size.height - 46)

            ZStack {
                PowerFlowLines(snapshot: snapshot, isAnimating: isAnimating && !reduceMotion)
                    .accessibilityHidden(true)

                FlowNode(
                    icon: "powerplug.fill",
                    title: "Adapter",
                    value: snapshot.externalConnected == false
                        ? "Disconnected" : ReadingFormat.watts(snapshot.adapterPowerWatts),
                    active: snapshot.externalConnected == true && !snapshot.isStale
                )
                .position(adapter)

                FlowNode(
                    icon: "laptopcomputer",
                    title: "Mac",
                    value: ReadingFormat.watts(snapshot.systemPowerWatts),
                    active: snapshot.systemPowerWatts != nil
                )
                .position(mac)

                FlowNode(
                    icon: snapshot.batteryIcon,
                    title: "Battery \(snapshot.chargeText)",
                    value: batteryValue,
                    active: abs(snapshot.batteryPowerWatts ?? 0) > 0.2
                )
                .position(battery)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    private var batteryValue: String {
        ReadingFormat.watts(snapshot.batteryPowerWatts, signed: true)
    }

    private var accessibilitySummary: String {
        "\(snapshot.displayDetail). Mac uses \(ReadingFormat.watts(snapshot.systemPowerWatts)). "
            + "Battery power is \(batteryValue)."
    }

}

private struct FlowNode: View {
    let icon: String
    let title: String
    let value: String
    let active: Bool

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(AppTypography.icon)
            Text(title)
                .font(AppTypography.body)
                .lineLimit(1)
            Text(value)
                .font(AppTypography.reading)
                .lineLimit(1)
        }
        .frame(width: 112, height: 78)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(active ? Color.accentColor.opacity(0.55) : Color.secondary.opacity(0.16))
        }
    }
}
