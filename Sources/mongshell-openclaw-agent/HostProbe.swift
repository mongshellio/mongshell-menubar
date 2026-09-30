import Foundation
import IOKit.ps

/// How bad a host signal is. Declaration order is severity order — the
/// synthesized `Comparable` is what "worst of" relies on. No `down`: a host
/// that is down publishes nothing, and clients notice that by staleness.
enum HostLevel: Comparable {
    case ok
    case warning
    case critical
}

/// What the internal battery and the power adapter say, before any judgement.
struct PowerReading: Equatable {
    let pluggedIn: Bool
    let charging: Bool
    /// 0...100, or nil when the battery doesn't report a usable capacity.
    let batteryPercent: Int?
}

/// Free space on the volume holding the home directory, before any judgement.
struct DiskReading: Equatable {
    let availableBytes: Int64
}

/// The judged host signals (Decision #31). A signal that can't be read is nil;
/// a `HostStatus` exists only when at least one signal could be.
struct HostStatus: Equatable {
    struct Power: Equatable {
        let reading: PowerReading
        let level: HostLevel
    }

    struct Disk: Equatable {
        let reading: DiskReading
        let level: HostLevel
    }

    let power: Power?
    let disk: Disk?
    /// The worst level among the signals present.
    let level: HostLevel
}

/// The level of each signal, nil where there is none — what tells one host
/// verdict from another in the agent's log. The overall level follows from
/// the pair, so it isn't part of it.
struct HostSignalLevels: Equatable {
    let power: HostLevel?
    let disk: HostLevel?

    init(_ host: HostStatus?) {
        power = host?.power?.level
        disk = host?.disk?.level
    }
}

/// Mechanism: reads the raw host signals. No thresholds here — see `HostRules`.
enum HostProbe {
    // MARK: Power

    /// The internal battery's state, or nil on a mac without one.
    static func readPower() -> PowerReading? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return nil }
        let providing = IOPSGetProvidingPowerSourceType(blob)?.takeUnretainedValue() as String?
        let handles = (IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as [CFTypeRef]?) ?? []
        let sources = handles.compactMap { handle in
            IOPSGetPowerSourceDescription(blob, handle)?.takeUnretainedValue() as? [String: Any]
        }
        return interpretPower(providing: providing, sources: sources)
    }

    /// Turns IOKit's power-source dictionaries into a reading. Pure, so the
    /// battery-less shapes (no sources, UPS only, battery bay empty) are
    /// testable without the hardware.
    ///
    /// Only an internal battery counts; a UPS is out of scope. When nothing
    /// says where power comes from there is no reading.
    static func interpretPower(providing: String?, sources: [[String: Any]]) -> PowerReading? {
        let battery = sources.first { source in
            source[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
                && source[kIOPSIsPresentKey] as? Bool != false
        }
        guard let battery else { return nil }
        let batteryState = battery[kIOPSPowerSourceStateKey] as? String
        guard let pluggedIn = pluggedIn(providing: providing, batteryState: batteryState) else {
            return nil
        }
        return PowerReading(
            pluggedIn: pluggedIn,
            charging: battery[kIOPSIsChargingKey] as? Bool ?? false,
            batteryPercent: batteryPercent(
                current: battery[kIOPSCurrentCapacityKey] as? Int,
                max: battery[kIOPSMaxCapacityKey] as? Int))
    }

    /// `providing` is the system-wide answer and wins: anything but the
    /// internal battery (AC, or a UPS feeding the adapter) means the battery
    /// isn't what keeps the server up. The battery's own state is the
    /// fallback, and there only its two definite values count — any other
    /// ("Off Line") says the battery isn't supplying, not what is.
    private static func pluggedIn(providing: String?, batteryState: String?) -> Bool? {
        if let providing { return providing != kIOPMBatteryPowerKey }
        if batteryState == kIOPSACPowerValue { return true }
        if batteryState == kIOPSBatteryPowerValue { return false }
        return nil
    }

    static let fullPercent = 100

    /// Current capacity is only meaningful relative to max capacity (IOKit
    /// leaves the unit open), so without a positive max there is no percent.
    private static func batteryPercent(current: Int?, max: Int?) -> Int? {
        guard let current, let max, max > 0, current >= 0 else { return nil }
        let percent = (Double(current) / Double(max) * Double(fullPercent)).rounded()
        // Capped before the conversion: `Int(_:)` traps on a value past
        // `Int.max`, which a current far above max would produce.
        return Int(min(percent, Double(fullPercent)))
    }

    // MARK: Disk

    /// Free space on the volume holding the home directory — where openclaw
    /// and its logs live — or nil if the volume won't say.
    static func readDisk() -> DiskReading? {
        var home = FileManager.default.homeDirectoryForCurrentUser
        // URL caches resource values until the run loop turns, and this agent
        // has no run loop: without this a reused URL would repeat a stale size.
        home.removeAllCachedResourceValues()
        let values = try? home.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey,
        ])
        return interpretDisk(
            importantUsage: values?.volumeAvailableCapacityForImportantUsage,
            available: values?.volumeAvailableCapacity.map(Int64.init))
    }

    /// Prefers the "important usage" figure (counts purgeable space, matches
    /// what Finder shows). It reads 0 or nil on volumes that don't support it,
    /// so a non-positive value falls back to the plain figure — where 0 is a
    /// real answer: the disk is full.
    static func interpretDisk(importantUsage: Int64?, available: Int64?) -> DiskReading? {
        if let importantUsage, importantUsage > 0 {
            return DiskReading(availableBytes: importantUsage)
        }
        if let available, available >= 0 {
            return DiskReading(availableBytes: available)
        }
        return nil
    }
}

/// Policy: the single home of the host thresholds (Decision #31). Clients only
/// display the levels this agent publishes. No hysteresis — a value sitting on
/// a threshold may flip between levels from one probe to the next.
enum HostRules {
    /// On battery at or below this, the server is about to go dark.
    static let criticalBatteryPercent = 20

    /// Decimal, like Finder and the disk's label — not GiB.
    static let bytesPerGB: Int64 = 1_000_000_000
    static let diskWarningBelowBytes = 20 * bytesPerGB
    static let diskCriticalBelowBytes = 5 * bytesPerGB

    /// Plugged in is fine whatever the charge. On battery is already worth a
    /// warning — an always-on server lost its adapter — and an unreadable
    /// charge stays a warning rather than guessing either way.
    static func level(for power: PowerReading) -> HostLevel {
        if power.pluggedIn { return .ok }
        guard let percent = power.batteryPercent else { return .warning }
        return percent <= criticalBatteryPercent ? .critical : .warning
    }

    static func level(for disk: DiskReading) -> HostLevel {
        if disk.availableBytes < diskCriticalBelowBytes { return .critical }
        if disk.availableBytes < diskWarningBelowBytes { return .warning }
        return .ok
    }

    /// Judges each signal that could be read; nil when none could.
    static func judge(power: PowerReading?, disk: DiskReading?) -> HostStatus? {
        let judgedPower = power.map { HostStatus.Power(reading: $0, level: level(for: $0)) }
        let judgedDisk = disk.map { HostStatus.Disk(reading: $0, level: level(for: $0)) }
        guard let worst = [judgedPower?.level, judgedDisk?.level].compactMap({ $0 }).max() else {
            return nil
        }
        return HostStatus(power: judgedPower, disk: judgedDisk, level: worst)
    }
}
