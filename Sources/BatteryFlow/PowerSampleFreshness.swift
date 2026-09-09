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
        let counters = [
            (raw.powerSampleCounter, old.powerSampleCounter),
            (raw.batteryPowerSampleCounter, old.batteryPowerSampleCounter),
            (raw.systemLoadSampleCounter, old.systemLoadSampleCounter)
        ]
        // An adapter-input counter may correctly stop while the battery and system-load
        // channels continue updating. Any changed channel proves this is a new sample.
        if counters.contains(where: { current, previous in
            guard let current, let previous else { return false }
            return current != previous
        }) {
            return true
        }
        // A changed measurement is also evidence of an update on hardware that omits
        // one or more counters; a repeated read or connection flag alone is not.
        return [raw.directAdapterPowerMilliwatts, raw.directBatteryPowerMilliwatts,
                raw.directSystemLoadMilliwatts, raw.systemVoltageInMillivolts,
                raw.systemCurrentInMilliamps, raw.voltageMillivolts, raw.amperageMilliamps]
            != [old.directAdapterPowerMilliwatts, old.directBatteryPowerMilliwatts,
                old.directSystemLoadMilliwatts, old.systemVoltageInMillivolts,
                old.systemCurrentInMilliamps, old.voltageMillivolts, old.amperageMilliamps]
    }
}

/// Keeps validation state out of the visual presentation. Invalid observations are
/// still recorded as such, while the panel holds its last coherent set of values.
struct PowerPresentation {
    private var lastStableByConnection: [Bool: PowerSnapshot] = [:]
    private var lastStableWithoutConnection: PowerSnapshot?

    mutating func present(_ observation: PowerSnapshot) -> PowerSnapshot {
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
