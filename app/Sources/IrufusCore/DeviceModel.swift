// Disk descriptions and the (pure, unit-tested) eligibility policy that decides
// which disks may ever be selected as a write target.

import Foundation

public struct DiskPartition: Sendable, Hashable, Identifiable {
    public var id: String { bsdName }
    public let bsdName: String
    public let volumeName: String?
    public let content: String?
    public let fileSystem: String?
    public let size: UInt64
    public let mountPoint: String?

    public init(bsdName: String, volumeName: String?, content: String?, fileSystem: String?, size: UInt64, mountPoint: String?) {
        self.bsdName = bsdName
        self.volumeName = volumeName
        self.content = content
        self.fileSystem = fileSystem
        self.size = size
        self.mountPoint = mountPoint
    }
}

/// Facts about a whole disk, as reported by Disk Arbitration and IOKit.
public struct DiskFacts: Sendable, Hashable {
    public var bsdName: String
    public var mediaName: String?
    public var vendor: String?
    public var model: String?
    public var revision: String?
    public var size: UInt64
    public var blockSize: UInt32
    public var removable: Bool
    public var ejectable: Bool
    public var writable: Bool
    public var isInternal: Bool
    /// "USB", "Secure Digital", "SATA", "PCI-Express", "Disk Image", "Virtual Interface", ...
    public var connection: String?
    public var busPath: String?
    public var major: Int32?
    public var minor: Int32?
    public var contentType: String?
    public var isSynthesized: Bool
    /// BSD names of every IOMedia below this disk (partitions, APFS volumes...).
    public var descendantBSDNames: Set<String>

    public init(bsdName: String, size: UInt64, blockSize: UInt32) {
        self.bsdName = bsdName
        self.size = size
        self.blockSize = blockSize
        removable = false
        ejectable = false
        writable = false
        isInternal = true
        isSynthesized = false
        descendantBSDNames = []
    }

    public var isVirtual: Bool {
        connection == "Disk Image" || connection == "Virtual Interface"
    }

    /// Stable identity used for the exclusion list and the pre-write check.
    public var identityKey: String {
        [vendor ?? "", model ?? "", String(size), busPath ?? ""].joined(separator: "|")
    }

    public var displayName: String {
        let parts = [vendor, model].compactMap { $0?.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if !parts.isEmpty { return parts.joined(separator: " ") }
        return mediaName ?? bsdName
    }
}

public enum DeviceExclusion: String, Sendable, Hashable, CaseIterable {
    case unidentified
    case internalDisk
    case bootDisk
    case sourceImageDisk
    case synthesized
    case readOnly
    case unsupportedConnection
    case usbHardDrive
    case diskImage
    case userExcluded
}

public struct EligibilityPolicy: Sendable, Hashable {
    public var showUSBHardDrives = false
    public var showDiskImages = false
    public var excludedIdentities: Set<String> = []
    /// BSD names of volumes that must never be touched (startup volume and friends).
    public var protectedBSDNames: Set<String> = []
    /// BSD names of the volume holding the selected source image.
    public var sourceBSDNames: Set<String> = []

    public init() {}

    static let flashConnections: Set<String> = ["USB", "Secure Digital"]

    public func evaluate(_ d: DiskFacts) -> DeviceExclusion? {
        let validName = d.bsdName.range(of: #"^disk[0-9]+$"#, options: .regularExpression) != nil
        if !validName || d.size == 0 || !(d.blockSize == 512 || d.blockSize == 4096) || d.major == nil || d.minor == nil {
            return .unidentified
        }
        let all = d.descendantBSDNames.union([d.bsdName])
        if !all.isDisjoint(with: protectedBSDNames) { return .bootDisk }
        if !all.isDisjoint(with: sourceBSDNames) { return .sourceImageDisk }
        if d.isSynthesized { return .synthesized }
        if d.isVirtual {
            return showDiskImages ? (d.writable ? nil : .readOnly) : .diskImage
        }
        if d.isInternal { return .internalDisk }
        guard let c = d.connection, Self.flashConnections.contains(c) else { return .unsupportedConnection }
        if !d.writable { return .readOnly }
        if !d.removable && !showUSBHardDrives { return .usbHardDrive }
        if excludedIdentities.contains(d.identityKey) { return .userExcluded }
        return nil
    }
}

public struct DiskDevice: Sendable, Hashable, Identifiable {
    public var id: String { facts.bsdName }
    public let facts: DiskFacts
    public let partitions: [DiskPartition]
    public let exclusion: DeviceExclusion?

    public init(facts: DiskFacts, partitions: [DiskPartition], exclusion: DeviceExclusion?) {
        self.facts = facts
        self.partitions = partitions
        self.exclusion = exclusion
    }

    public var isSelectable: Bool { exclusion == nil }
}

/// What the user must do to confirm a destructive operation on a device.
public enum ConfirmationLevel: Equatable, Sendable {
    /// A single explicit confirmation.
    case standard
    /// Additionally type the disk identifier (large or ambiguously identified disk).
    case typeIdentifier(reasons: [Reason])

    public enum Reason: String, Sendable {
        case largeDisk
        case noVendorOrModel
        case notRemovableMedia
        case virtualDisk
    }

    public static let largeDiskThreshold: UInt64 = 128_000_000_000

    public static func required(for d: DiskFacts) -> ConfirmationLevel {
        var reasons: [Reason] = []
        if d.size > largeDiskThreshold { reasons.append(.largeDisk) }
        if (d.vendor ?? "").trimmingCharacters(in: .whitespaces).isEmpty && (d.model ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
            reasons.append(.noVendorOrModel)
        }
        if !d.removable && !d.isVirtual { reasons.append(.notRemovableMedia) }
        if d.isVirtual { reasons.append(.virtualDisk) }
        return reasons.isEmpty ? .standard : .typeIdentifier(reasons: reasons)
    }
}

/// Snapshot taken when the user confirms; re-checked right before writing.
public struct DiskIdentity: Sendable, Hashable {
    public let bsdName: String
    public let size: UInt64
    public let blockSize: UInt32
    public let vendor: String?
    public let model: String?
    public let busPath: String?
    public let major: Int32?
    public let minor: Int32?

    public init(_ f: DiskFacts) {
        bsdName = f.bsdName
        size = f.size
        blockSize = f.blockSize
        vendor = f.vendor
        model = f.model
        busPath = f.busPath
        major = f.major
        minor = f.minor
    }

    public var rawDevicePath: String { "/dev/r\(bsdName)" }

    /// `st_rdev` the descriptor must have.
    public var expectedRdev: dev_t? {
        guard let major, let minor else { return nil }
        return dev_t((major << 24) | (minor & 0xFFFFFF))
    }
}
