import Foundation
import Testing
@testable import BatteryFlow

struct HistoryPowerFlowTests {
    @Test func chargingAndIdleSeparateAdapterSupplyFromMacConsumption() {
        let charging = HistoryPowerFlow(adapter: 30, system: 20, battery: 10)
        #expect(charging.adapter == 30)
        #expect(charging.mac == -20)
        #expect(charging.battery == -10)
        let idle = HistoryPowerFlow(adapter: 10, system: 10, battery: 0)
        #expect(idle.adapter == 10)
        #expect(idle.mac == -10)
        #expect(idle.battery == 0)
    }

    @Test func batteryDischargeIsSupplyWithOrWithoutAnAdapter() {
        let batteryOnly = HistoryPowerFlow(adapter: 0, system: 8, battery: -8)
        #expect(batteryOnly.adapter == 0)
        #expect(batteryOnly.mac == -8)
        #expect(batteryOnly.battery == 8)
        let combined = HistoryPowerFlow(adapter: 15, system: 25, battery: -10)
        #expect(combined.adapter == 15)
        #expect(combined.mac == -25)
        #expect(combined.battery == 10)
    }

    @Test func batteryLabelsExplainDirectionAndPreserveMissingReadings() {
        func label(_ value: Double?) -> String {
            HistoryPowerFlow(adapter: nil, system: nil, battery: value).batteryLabel
        }
        #expect(label(12.3) == "Charging 12.3 W")
        #expect(label(-8.1) == "Discharging 8.1 W")
        for idle in [-0.2, -0.0, 0, 0.2] { #expect(label(idle) == "Idle") }
        #expect(label(nil) == "—")
        let missing = HistoryPowerFlow(adapter: nil, system: nil, battery: nil)
        #expect(missing.adapter == nil && missing.mac == nil && missing.battery == nil)
        let zero = HistoryPowerFlow(adapter: 0, system: 0, battery: -0.0)
        #expect(zero.mac?.sign == .plus && zero.battery?.sign == .plus)
    }

    @Test func signedChartPreservesStoredValuesCSVAndConsumptionStatistics() throws {
        var point = historyPoint()
        point.adapterPowerWatts = 30
        point.systemPowerWatts = 20
        point.batteryPowerWatts = 10
        point.state = .charging
        let sample = try #require(HistoryAggregation.samples([point], range: .hour, now: testDate).first)
        let flow = HistoryPowerFlow(adapter: sample.adapter, system: sample.system, battery: sample.battery)
        #expect(flow.mac == -20 && flow.battery == -10)
        #expect(point.systemPowerWatts == 20 && point.batteryPowerWatts == 10)
        #expect(HistorySummary(points: [point]).mac.average == 20)
        let csv = try #require(String(data: HistoryCSV.encode([point]), encoding: .utf8))
        let row = csv.components(separatedBy: "\r\n")[1].components(separatedBy: ",")
        #expect(row[5] == "30.0")
        #expect(row[6] == "10.0")
        #expect(row[7] == "20.0")
    }
}
