// app/Sources/AiTermCore/Backpack/BackpackState.swift
import Foundation

/// What Backpack Mode still needs before it can turn on.
public struct BackpackSetup: Equatable, Sendable {
    public enum Step: Equatable, Sendable { case sleepRule, location }

    public var sleepRule: Bool
    public var location: Bool
    public var network: String?

    public init(sleepRule: Bool, location: Bool, network: String?) {
        self.sleepRule = sleepRule
        self.location = location
        self.network = network
    }

    /// The steps Settings › Backpack › Set Up… runs, in order. A missing network is a field, not a step.
    public var missingSteps: [Step] {
        (sleepRule ? [] : [.sleepRule]) + (location ? [] : [.location])
    }

    public var isComplete: Bool { missingSteps.isEmpty && network != nil }
}

/// The mode while it is on.
public struct BackpackStatus: Equatable, Sendable {
    public var network: String
    /// Whether the Mac is on `network` now.
    public var joined: Bool
    public var power: PowerReading
    /// The cutoff in force, as it was when the mode turned on.
    public var cutoff: Int

    public init(network: String, joined: Bool, power: PowerReading, cutoff: Int) {
        self.network = network
        self.joined = joined
        self.power = power
        self.cutoff = cutoff
    }

    /// On battery, within 5 points of the cutoff.
    public var nearCutoff: Bool {
        guard power.onBattery, let level = power.level else { return false }
        return level <= cutoff + 5
    }

    /// Drawn amber: off the chosen network, or close to turning itself off.
    public var degraded: Bool { !joined || nearCutoff }
}

public enum BackpackState: Equatable, Sendable {
    case off
    case on(BackpackStatus)

    public var isOn: Bool {
        if case .on = self { true } else { false }
    }
}

/// Why the mode stayed off. Each is a toast.
public enum BackpackRefusal: Error, Equatable, Sendable {
    /// No sudoers rule, no Location access, or no network chosen.
    case needsSetup
    case batteryLow(level: Int)
    case notInRange(network: String)
    case joinFailed(network: String)

    public var message: String {
        switch self {
        case .needsSetup: "Backpack Mode needs setup: Settings › Backpack"
        case .batteryLow(let level): "Battery at \(level) %: Backpack Mode stays off"
        case .notInRange(let network): "\(network) isn’t in range: Backpack Mode stays off"
        case .joinFailed(let network): "Couldn’t join \(network): check its password in Settings › Backpack"
        }
    }
}

/// What one 60 s check found.
public enum BackpackTick: Equatable, Sendable {
    case unchanged
    case changed
    /// The battery reached the cutoff and the mode turned itself off.
    case turnedOff(level: Int)
}

/// The toasts that are not refusals.
public enum BackpackCopy {
    public static func turnedOn(network: String) -> String { "Backpack Mode on · joined \(network)" }
    public static func cutOff(level: Int) -> String { "Battery at \(level) %: Backpack Mode turned off" }
}
