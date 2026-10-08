// Pure decisions about what can be written where, used by the UI to show only
// options that apply and to block inconsistent configurations.

import Foundation

public enum PlanIssue: Equatable, Sendable {
    case noDevice
    case noImage
    case deviceNotSelectable(DeviceExclusion)
    case modeUnavailable
    case imageLargerThanDevice(needed: UInt64, available: UInt64)
    case deviceTooSmallForFat32
    case schemeRequired
    case answerFileConflict
    case invalidAccountName
}

public struct WriteOptions: Equatable, Sendable {
    public var mode: WriteMode
    public var scheme: PartitionScheme = .gpt
    public var clusterSize: UInt32?
    public var label: String = ""
    public var verify: Bool = true
    public var wueEnabled: Bool = false
    public var wue = WueSelection()

    public init(mode: WriteMode) {
        self.mode = mode
    }
}

/// Windows customisation chosen in the UI (mapped to `WueOptions`).
public struct WueSelection: Equatable, Sendable {
    public var bypassRequirements = true
    public var noOnlineAccount = true
    public var createLocalAccount = false
    public var accountName = ""
    public var disableDataCollection = false
    public var copyRegionalSettings = false
    public var disableBitlocker = false

    public init() {}
}

public enum WritePlanner {
    /// Initial options for an analysed image (never selects a device).
    public static func defaults(for report: ImageReport, verify: Bool) -> WriteOptions? {
        guard let mode = report.recommendedMode ?? report.modes.first else { return nil }
        var o = WriteOptions(mode: mode)
        o.verify = verify
        o.label = report.label ?? ""
        o.scheme = .gpt
        if let w = report.iso?.windows {
            o.wueEnabled = !w.hasExistingAnswerFile && w.unattendArch != nil
            o.wue.bypassRequirements = w.isWindows11
        }
        return o
    }

    public static func windowsOptionsAvailable(_ report: ImageReport, mode: WriteMode) -> Bool {
        guard mode == .isoExtract, let w = report.iso?.windows else { return false }
        return !w.hasExistingAnswerFile && w.unattendArch != nil
    }

    public static func wueOptions(_ sel: WueSelection, report: ImageReport, locale: LocaleSettings?) -> WueOptions? {
        guard let w = report.iso?.windows, let arch = w.unattendArch else { return nil }
        var o = WueOptions(arch: arch)
        o.bypassRequirements = sel.bypassRequirements && w.isWindows11
        o.noOnlineAccount = sel.noOnlineAccount
        let name = sel.accountName.trimmingCharacters(in: .whitespaces)
        o.localAccount = sel.createLocalAccount && !name.isEmpty ? name : nil
        o.disableDataCollection = sel.disableDataCollection
        o.locale = sel.copyRegionalSettings ? locale : nil
        o.disableBitlocker = sel.disableBitlocker
        return o.isEmpty ? nil : o
    }

    public static func issues(report: ImageReport?, device: DiskDevice?, options: WriteOptions?,
                              accountNameValid: Bool = true) -> [PlanIssue] {
        var out: [PlanIssue] = []
        guard let device else { out.append(.noDevice); return out + (report == nil ? [.noImage] : []) }
        if let ex = device.exclusion { out.append(.deviceNotSelectable(ex)) }
        guard let report, let options else { out.append(.noImage); return out }
        if !report.modes.contains(options.mode) { out.append(.modeUnavailable) }
        switch options.mode {
        case .dd:
            if let size = report.imageSize, size > device.facts.size {
                out.append(.imageLargerThanDevice(needed: size, available: device.facts.size))
            }
        case .isoExtract:
            if let total = report.iso?.totalFileBytes, total + 64 << 20 > device.facts.size {
                out.append(.imageLargerThanDevice(needed: total, available: device.facts.size))
            } else if device.facts.size < 128 << 20 {
                out.append(.deviceTooSmallForFat32)
            }
            if options.wueEnabled && report.iso?.windows?.hasExistingAnswerFile == true {
                out.append(.answerFileConflict)
            }
            if options.wueEnabled && options.wue.createLocalAccount && !accountNameValid {
                out.append(.invalidAccountName)
            }
        }
        return out
    }

    public static func request(options: WriteOptions, report: ImageReport, locale: LocaleSettings?) -> WriteRequest {
        switch options.mode {
        case .dd:
            return WriteRequest(mode: .dd, verify: options.verify)
        case .isoExtract:
            let label = options.label.trimmingCharacters(in: .whitespaces)
            let wue = options.wueEnabled && windowsOptionsAvailable(report, mode: .isoExtract)
                ? wueOptions(options.wue, report: report, locale: locale) : nil
            return WriteRequest(mode: .isoExtract, verify: options.verify, scheme: options.scheme,
                                clusterSize: options.clusterSize, label: label.isEmpty ? nil : label, wue: wue)
        }
    }

    /// Firmware targets expected to boot the result, for display.
    public static func targets(report: ImageReport, mode: WriteMode) -> [String] {
        mode == .dd ? report.ddTargets : report.extractTargets
    }
}

public enum Format {
    public static func bytes(_ n: UInt64, binary: Bool = false) -> String {
        let f = ByteCountFormatter()
        f.countStyle = binary ? .binary : .decimal
        f.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        return f.string(fromByteCount: Int64(clamping: n))
    }

    public static func rate(_ bps: Double, binary: Bool = false) -> String {
        guard bps.isFinite, bps > 0 else { return "—" }
        return bytes(UInt64(bps), binary: binary) + "/s"
    }

    public static func duration(_ t: TimeInterval) -> String {
        let f = DateComponentsFormatter()
        f.allowedUnits = t >= 3600 ? [.hour, .minute] : [.minute, .second]
        f.unitsStyle = .abbreviated
        return f.string(from: max(0, t)) ?? "—"
    }
}
