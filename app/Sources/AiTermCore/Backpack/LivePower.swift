import Foundation
import IOKit.ps

/// The internal battery, read when asked. A Mac without one reads as `.mains`.
public struct IOKitPowerSource: PowerSource {
    public init() {}

    public func reading() -> PowerReading {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return .mains }
        let descriptions = list.compactMap { IOPSGetPowerSourceDescription(info, $0)?.takeUnretainedValue() as? [String: Any] }
        return Self.reading(from: descriptions)
    }

    /// From IOKit's power-source descriptions: the internal battery's charge as a percentage of its
    /// maximum, and whether the Mac is running on it.
    static func reading(from descriptions: [[String: Any]]) -> PowerReading {
        guard let battery = descriptions.first(where: { $0[kIOPSTypeKey] as? String == kIOPSInternalBatteryType }) else { return .mains }
        let onBattery = battery[kIOPSPowerSourceStateKey] as? String == kIOPSBatteryPowerValue
        guard let current = battery[kIOPSCurrentCapacityKey] as? Int, let maximum = battery[kIOPSMaxCapacityKey] as? Int,
              maximum > 0 else { return PowerReading(level: nil, onBattery: onBattery) }
        return PowerReading(level: Int((Double(current) / Double(maximum) * 100).rounded()), onBattery: onBattery)
    }
}
