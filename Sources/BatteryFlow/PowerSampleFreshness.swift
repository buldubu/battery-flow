import Foundation

/// Connection status and wattages can be published at different times by macOS.
struct PowerSampleFreshness {
    private var previous: RawPowerTelemetry?
    private var waiting = false

    mutating func invalidate() {
        if previous != nil { waiting = true }
    }

    mutating func snapshot(from raw: RawPowerTelemetry) -> PowerSnapshot {
        let changedState = previous.map {
            $0.externalConnected != raw.externalConnected || $0.isCharging != raw.isCharging
        } ?? false
        if changedState { waiting = true }

        // The sample counter belongs to the wattage telemetry. UpdateTime belongs to
        // the whole registry entry and can change when only the status changes.
        if let previous, hasNewPowerSample(raw, after: previous) { waiting = false }
        if let registrySource = raw.registryExternalConnected,
           let source = raw.externalConnected, registrySource != source {
            waiting = true
        }
        previous = raw
        var result = PowerMath.snapshot(from: raw)
        guard waiting else { return result }
        result.adapter = .unavailable
        result.battery = .unavailable
        result.system = .unavailable
        result.quality = .partial
        result.isAwaitingPowerData = true
        result.powerUpdatedAt = nil
        result.errorMessage = nil
        result.state = PowerMath.classify(externalConnected: raw.externalConnected,
            isCharging: raw.isCharging, isFullyCharged: raw.isFullyCharged, batteryPowerWatts: nil)
        return result
    }

    private func hasNewPowerSample(_ raw: RawPowerTelemetry, after old: RawPowerTelemetry) -> Bool {
        // A channel's counter is authoritative when available. Only use changes
        // to the measurements actually supplying that channel when counters are absent.
        func changed(_ counter: Int64?, _ oldCounter: Int64?,
                     _ values: [Int64?], _ oldValues: [Int64?]) -> Bool {
            if let counter, let oldCounter { return counter != oldCounter }
            return values != oldValues
        }
        func inputs(_ direct: Int64?, _ voltage: Int64?, _ current: Int64?) -> [Int64?] {
            direct.map { [$0] } ?? [voltage, current]
        }
        return changed(raw.powerSampleCounter, old.powerSampleCounter,
                       inputs(raw.directAdapterPowerMilliwatts, raw.systemVoltageInMillivolts, raw.systemCurrentInMilliamps),
                       inputs(old.directAdapterPowerMilliwatts, old.systemVoltageInMillivolts, old.systemCurrentInMilliamps))
            || changed(raw.batteryPowerSampleCounter, old.batteryPowerSampleCounter,
                       inputs(raw.directBatteryPowerMilliwatts, raw.voltageMillivolts, raw.amperageMilliamps),
                       inputs(old.directBatteryPowerMilliwatts, old.voltageMillivolts, old.amperageMilliamps))
            || changed(raw.systemLoadSampleCounter, old.systemLoadSampleCounter,
                       [raw.directSystemLoadMilliwatts], [old.directSystemLoadMilliwatts])
    }
}

/// Keeps validation state out of the visual presentation. Invalid observations are
/// still recorded as such, while the panel holds its last coherent set of values.
struct PowerPresentation {
    private var lastStableByConnection: [Bool: PowerSnapshot] = [:]
    private var lastStableWithoutConnection: PowerSnapshot?

    private var previousConnection: Bool?
    private var connectionDeadline: Date?

    mutating func present(_ observation: PowerSnapshot) -> PowerSnapshot {
        var observation = observation
        if observation.externalConnected == true && previousConnection == false {
            connectionDeadline = observation.timestamp?.addingTimeInterval(3)
        }
        previousConnection = observation.externalConnected
        if observation.externalConnected != true || observation.isCharging == true
            || observation.isFullyCharged == true {
            connectionDeadline = nil
        }
        if let deadline = connectionDeadline, let now = observation.timestamp {
            observation.isConnecting = now < deadline && observation.state == .paused
            if now >= deadline { connectionDeadline = nil }
        }
        if observation.isAwaitingPowerData || observation.quality == .inconsistent {
            guard let lastStable = stableSnapshot(matching: observation.externalConnected) else { return observation }
            var result = observation
            result.adapter = lastStable.adapter
            result.battery = lastStable.battery
            result.system = lastStable.system
            result.powerUpdatedAt = lastStable.powerUpdatedAt
            result.isAwaitingPowerData = true
            // A transition is expected to settle; persistent read failures still use
            // the normal stale/error presentation.
            result.errorMessage = nil
            return result
        }
        let result = PowerMath.smooth(observation, previous: stableSnapshot(matching: observation.externalConnected))
        if result.quality == .valid {
            if let connection = result.externalConnected { lastStableByConnection[connection] = result }
            else { lastStableWithoutConnection = result }
        }
        return result
    }

    private func stableSnapshot(matching connection: Bool?) -> PowerSnapshot? {
        connection.flatMap { lastStableByConnection[$0] } ?? (connection == nil ? lastStableWithoutConnection : nil)
    }
}
