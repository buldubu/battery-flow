import Foundation
import IOKit
import IOKit.ps

enum BatteryTelemetryError: LocalizedError {
    case serviceUnavailable, propertyReadFailed(kern_return_t), invalidProperties
    var errorDescription: String? {
        switch self {
        case .serviceUnavailable: "AppleSmartBattery service is unavailable"
        case let .propertyReadFailed(code): "Could not read battery properties (IOKit error \(code))"
        case .invalidProperties: "Battery properties had an unexpected format"
        }
    }
}

protocol TelemetryReading: Sendable {
    func read() async throws -> RawPowerTelemetry
}

actor BatteryTelemetryReader: TelemetryReading {
    func read() throws -> RawPowerTelemetry {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != IO_OBJECT_NULL else { throw BatteryTelemetryError.serviceUnavailable }
        defer { IOObjectRelease(service) }
        var unmanaged: Unmanaged<CFMutableDictionary>?
        let result = IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0)
        guard result == KERN_SUCCESS else { throw BatteryTelemetryError.propertyReadFailed(result) }
        guard let properties = unmanaged?.takeRetainedValue() as? [String: Any] else {
            throw BatteryTelemetryError.invalidProperties
        }
        return Self.decode(properties, powerSource: Self.powerSourceDescription() ?? [:])
    }

    // Pure decoding also allows missing-key and sentinel fixtures without touching hardware.
    static func decode(_ properties: [String: Any], powerSource: [String: Any] = [:]) -> RawPowerTelemetry {
        let adapter = properties["AdapterDetails"] as? [String: Any] ?? [:]
        let telemetry = properties["PowerTelemetryData"] as? [String: Any] ?? [:]
        let sourceState = powerSource[kIOPSPowerSourceStateKey] as? String
        let connected: Bool? = sourceState == kIOPSACPowerValue ? true
            : (sourceState == kIOPSBatteryPowerValue ? false : boolean(properties["ExternalConnected"]))
        return RawPowerTelemetry(
            chargePercent: integer(powerSource[kIOPSCurrentCapacityKey] ?? properties["CurrentCapacity"]),
            rawCurrentCapacity: signedInteger(properties["AppleRawCurrentCapacity"]),
            rawMaxCapacity: signedInteger(properties["AppleRawMaxCapacity"]),
            rawTemperature: signedInteger(properties["Temperature"]),
            cycleCount: integer(properties["CycleCount"]),
            externalConnected: connected,
            isCharging: boolean(powerSource[kIOPSIsChargingKey] ?? properties["IsCharging"]),
            isFullyCharged: boolean(properties["FullyCharged"]),
            voltageMillivolts: signedInteger(properties["Voltage"]),
            amperageMilliamps: signedInteger(properties["Amperage"]),
            adapterRatingWatts: signedInteger(adapter["Watts"]),
            systemVoltageInMillivolts: signedInteger(telemetry["SystemVoltageIn"]),
            systemCurrentInMilliamps: signedInteger(telemetry["SystemCurrentIn"]),
            directAdapterPowerMilliwatts: signedInteger(telemetry["SystemPowerIn"]),
            directBatteryPowerMilliwatts: signedInteger(telemetry["BatteryPower"]),
            directSystemLoadMilliwatts: signedInteger(telemetry["SystemLoad"]),
            healthCondition: BatteryHealthSnapshot.nonempty(powerSource[kIOPSBatteryHealthConditionKey] as? String),
            healthEstimate: BatteryHealthSnapshot.nonempty(powerSource[kIOPSBatteryHealthKey] as? String),
            powerSampleCounter: signedInteger(telemetry["SystemPowerInAccumulatorCount"]).flatMap { $0 >= 0 ? $0 : nil },
            batteryPowerSampleCounter: signedInteger(telemetry["BatteryPowerAccumulatorCount"]).flatMap { $0 >= 0 ? $0 : nil },
            systemLoadSampleCounter: signedInteger(telemetry["SystemLoadAccumulatorCount"]).flatMap { $0 >= 0 ? $0 : nil },
            registryExternalConnected: boolean(properties["ExternalConnected"])
        )
    }

    private static func powerSourceDescription() -> [String: Any]? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in sources {
            if let values = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
               values[kIOPSTypeKey] as? String == kIOPSInternalBatteryType { return values }
        }
        return nil
    }
    private static func signedInteger(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        // Exact conversion rejects unsigned sentinels, fractions and overflow instead of wrapping them.
        return Int64(exactly: number.doubleValue)
    }
    private static func integer(_ value: Any?) -> Int? { signedInteger(value).flatMap(Int.init(exactly:)) }
    private static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, number == 0 || number == 1 else { return nil }
        return number.boolValue
    }
}
