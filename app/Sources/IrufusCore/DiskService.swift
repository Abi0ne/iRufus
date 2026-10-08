// Disk enumeration and control through Disk Arbitration (+ IOKit for the
// media tree). Runs on the main queue.

import DiskArbitration
import Foundation
import IOKit

@MainActor
public final class DiskService {
    public private(set) var devices: [DiskDevice] = []
    public var policy = EligibilityPolicy() {
        didSet { scheduleRefresh() }
    }
    public var onChange: (([DiskDevice]) -> Void)?

    private let session: DASession
    private var disks: [String: DADisk] = [:]
    private var refreshPending = false
    private var blockedWholeDisk: String?

    public init?() {
        guard let s = DASessionCreate(kCFAllocatorDefault) else { return nil }
        session = s
        DASessionSetDispatchQueue(session, DispatchQueue.main)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        DARegisterDiskAppearedCallback(session, nil, { disk, ctx in
            guard let ctx else { return }
            let me = Unmanaged<DiskService>.fromOpaque(ctx).takeUnretainedValue()
            MainActor.assumeIsolated { me.diskAppeared(disk) }
        }, ctx)
        DARegisterDiskDisappearedCallback(session, nil, { disk, ctx in
            guard let ctx else { return }
            let me = Unmanaged<DiskService>.fromOpaque(ctx).takeUnretainedValue()
            MainActor.assumeIsolated { me.diskDisappeared(disk) }
        }, ctx)
        DARegisterDiskDescriptionChangedCallback(session, nil, nil, { _, _, ctx in
            guard let ctx else { return }
            let me = Unmanaged<DiskService>.fromOpaque(ctx).takeUnretainedValue()
            MainActor.assumeIsolated { me.scheduleRefresh() }
        }, ctx)
        DARegisterDiskMountApprovalCallback(session, nil, { disk, ctx in
            guard let ctx else { return nil }
            let me = Unmanaged<DiskService>.fromOpaque(ctx).takeUnretainedValue()
            let deny = MainActor.assumeIsolated { me.shouldBlockMount(disk) }
            guard deny else { return nil }
            let dissenter = DADissenterCreate(kCFAllocatorDefault, DAReturn(kDAReturnBusy), "iRufus is writing to this disk" as CFString)
            return Unmanaged.passRetained(dissenter)
        }, ctx)
    }

    // MARK: Enumeration

    private func bsdName(_ disk: DADisk) -> String? {
        DADiskGetBSDName(disk).map { String(cString: $0) }
    }

    private func diskAppeared(_ disk: DADisk) {
        guard let name = bsdName(disk) else { return }
        disks[name] = disk
        scheduleRefresh()
    }

    private func diskDisappeared(_ disk: DADisk) {
        guard let name = bsdName(disk) else { return }
        disks.removeValue(forKey: name)
        scheduleRefresh()
    }

    public func scheduleRefresh() {
        guard !refreshPending else { return }
        refreshPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            MainActor.assumeIsolated {
                self?.refreshPending = false
                self?.refresh()
            }
        }
    }

    public func refresh() {
        var protected = Self.protectedBSDNames()
        protected.formUnion(policy.protectedBSDNames)
        var effective = policy
        effective.protectedBSDNames = protected
        var result: [DiskDevice] = []
        for (name, disk) in disks {
            guard let desc = DADiskCopyDescription(disk) as? [CFString: Any],
                  desc[kDADiskDescriptionMediaWholeKey] as? Bool == true else { continue }
            let facts = Self.facts(name: name, disk: disk, desc: desc)
            let partitions = self.partitions(of: name)
            result.append(DiskDevice(facts: facts, partitions: partitions, exclusion: effective.evaluate(facts)))
        }
        result.sort { ($0.facts.bsdName.count, $0.facts.bsdName) < ($1.facts.bsdName.count, $1.facts.bsdName) }
        devices = result
        onChange?(result)
    }

    /// Current facts for one disk (fresh Disk Arbitration description).
    public func currentFacts(bsdName: String) -> DiskFacts? {
        guard let disk = disks[bsdName] ?? DADiskCreateFromBSDName(kCFAllocatorDefault, session, bsdName),
              let desc = DADiskCopyDescription(disk) as? [CFString: Any] else { return nil }
        return Self.facts(name: bsdName, disk: disk, desc: desc)
    }

    static func facts(name: String, disk: DADisk, desc: [CFString: Any]) -> DiskFacts {
        let size = (desc[kDADiskDescriptionMediaSizeKey] as? NSNumber)?.uint64Value ?? 0
        let block = (desc[kDADiskDescriptionMediaBlockSizeKey] as? NSNumber)?.uint32Value ?? 0
        var f = DiskFacts(bsdName: name, size: size, blockSize: block)
        func str(_ k: CFString) -> String? {
            (desc[k] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        }
        f.mediaName = str(kDADiskDescriptionMediaNameKey)
        f.vendor = str(kDADiskDescriptionDeviceVendorKey)
        f.model = str(kDADiskDescriptionDeviceModelKey)
        f.revision = str(kDADiskDescriptionDeviceRevisionKey)
        f.removable = desc[kDADiskDescriptionMediaRemovableKey] as? Bool ?? false
        f.ejectable = desc[kDADiskDescriptionMediaEjectableKey] as? Bool ?? false
        f.writable = desc[kDADiskDescriptionMediaWritableKey] as? Bool ?? false
        f.isInternal = desc[kDADiskDescriptionDeviceInternalKey] as? Bool ?? true
        f.connection = str(kDADiskDescriptionDeviceProtocolKey)
        f.busPath = str(kDADiskDescriptionBusPathKey) ?? str(kDADiskDescriptionDevicePathKey)
        f.major = (desc[kDADiskDescriptionMediaBSDMajorKey] as? NSNumber)?.int32Value
        f.minor = (desc[kDADiskDescriptionMediaBSDMinorKey] as? NSNumber)?.int32Value
        f.contentType = str(kDADiskDescriptionMediaContentKey)
        let media = DADiskCopyIOMedia(disk)
        if media != IO_OBJECT_NULL {
            f.isSynthesized = IOObjectConformsTo(media, "AppleAPFSMedia") != 0
                || Self.parentConforms(media, to: "AppleAPFSContainerScheme")
            f.descendantBSDNames = Self.descendantBSDNames(of: media)
            IOObjectRelease(media)
        }
        return f
    }

    private static func parentConforms(_ entry: io_registry_entry_t, to cls: String) -> Bool {
        var parent: io_registry_entry_t = IO_OBJECT_NULL
        guard IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent) == KERN_SUCCESS else { return false }
        defer { IOObjectRelease(parent) }
        return IOObjectConformsTo(parent, cls) != 0
    }

    private static func descendantBSDNames(of media: io_registry_entry_t) -> Set<String> {
        var names = Set<String>()
        var iter: io_iterator_t = IO_OBJECT_NULL
        guard IORegistryEntryCreateIterator(media, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &iter) == KERN_SUCCESS else {
            return names
        }
        defer { IOObjectRelease(iter) }
        var count = 0
        while case let entry = IOIteratorNext(iter), entry != IO_OBJECT_NULL {
            if let n = IORegistryEntryCreateCFProperty(entry, "BSD Name" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String {
                names.insert(n)
            }
            IOObjectRelease(entry)
            count += 1
            if count > 10_000 { break }
        }
        return names
    }

    /// Volumes macOS needs to run: the startup volume group, the user's home and this app.
    static func protectedBSDNames() -> Set<String> {
        var paths = ["/", "/System/Volumes/Data", "/System/Volumes/Preboot", "/System/Volumes/VM", "/System/Volumes/Update",
                     NSHomeDirectory(), Bundle.main.bundlePath]
        paths.append(contentsOf: (try? FileManager.default.contentsOfDirectory(atPath: "/Volumes"))?.compactMap { name in
            let p = "/Volumes/\(name)"
            // Time Machine destinations are protected as well.
            return FileManager.default.fileExists(atPath: "\(p)/Backups.backupdb") ? p : nil
        } ?? [])
        return Set(paths.compactMap(bsdNameOfVolume(containing:)))
    }

    /// BSD name (e.g. "disk3s1") of the volume containing `path`.
    public nonisolated static func bsdNameOfVolume(containing path: String) -> String? {
        var st = statfs()
        guard statfs(path, &st) == 0 else { return nil }
        let from = withUnsafeBytes(of: st.f_mntfromname) { raw in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
        guard from.hasPrefix("/dev/") else { return nil }
        return String(from.dropFirst(5))
    }

    private func partitions(of whole: String) -> [DiskPartition] {
        var parts: [DiskPartition] = []
        for (name, disk) in disks where name != whole && name.hasPrefix(whole + "s") {
            guard let desc = DADiskCopyDescription(disk) as? [CFString: Any] else { continue }
            let mount = (desc[kDADiskDescriptionVolumePathKey] as? URL)?.path
            parts.append(DiskPartition(
                bsdName: name,
                volumeName: (desc[kDADiskDescriptionVolumeNameKey] as? String)?.nilIfEmpty,
                content: (desc[kDADiskDescriptionMediaContentKey] as? String)?.nilIfEmpty,
                fileSystem: (desc[kDADiskDescriptionVolumeKindKey] as? String)?.nilIfEmpty,
                size: (desc[kDADiskDescriptionMediaSizeKey] as? NSNumber)?.uint64Value ?? 0,
                mountPoint: mount))
        }
        return parts.sorted { $0.bsdName.localizedStandardCompare($1.bsdName) == .orderedAscending }
    }

    // MARK: Control

    private func shouldBlockMount(_ disk: DADisk) -> Bool {
        guard let blocked = blockedWholeDisk, let name = bsdName(disk) else { return false }
        return name == blocked || name.hasPrefix(blocked + "s")
    }

    /// Prevent macOS from mounting volumes of `bsdName` until `allowMounts()`.
    public func blockMounts(of bsdName: String) {
        blockedWholeDisk = bsdName
    }

    public func allowMounts() {
        blockedWholeDisk = nil
    }

    public struct DiskOperationError: Error, Sendable {
        public let status: Int32
        public let message: String?
    }

    private final class CallbackBox {
        let resume: (DADissenter?) -> Void
        init(_ r: @escaping (DADissenter?) -> Void) { resume = r }
    }

    private func perform(_ start: (UnsafeMutableRawPointer) -> Void) async throws {
        let dissenter: DADissenterInfo? = await withCheckedContinuation { cont in
            let box = CallbackBox { d in
                cont.resume(returning: d.map { DADissenterInfo(status: DADissenterGetStatus($0), text: DADissenterGetStatusString($0) as String?) })
            }
            start(Unmanaged.passRetained(box).toOpaque())
        }
        if let dissenter {
            throw DiskOperationError(status: dissenter.status, message: dissenter.text)
        }
    }

    private struct DADissenterInfo {
        let status: DAReturn
        let text: String?
    }

    private static let callback: DADiskUnmountCallback = { _, dissenter, ctx in
        guard let ctx else { return }
        let box = Unmanaged<CallbackBox>.fromOpaque(ctx).takeRetainedValue()
        box.resume(dissenter)
    }

    private func disk(_ bsdName: String) throws -> DADisk {
        guard let d = disks[bsdName] ?? DADiskCreateFromBSDName(kCFAllocatorDefault, session, bsdName) else {
            throw DiskOperationError(status: Int32(kDAReturnNotFound), message: nil)
        }
        return d
    }

    /// Unmount every volume of the whole disk.
    public func unmountWhole(_ bsdName: String, force: Bool = false) async throws {
        let d = try disk(bsdName)
        let opts = DADiskUnmountOptions(kDADiskUnmountOptionWhole) | (force ? DADiskUnmountOptions(kDADiskUnmountOptionForce) : 0)
        try await perform { DADiskUnmount(d, opts, Self.callback, $0) }
    }

    /// Ask macOS to mount the volumes of the whole disk again (best effort).
    public func mountWhole(_ bsdName: String) async throws {
        let d = try disk(bsdName)
        try await perform { DADiskMount(d, nil, DADiskMountOptions(kDADiskMountOptionWhole), Self.callback, $0) }
    }

    public func eject(_ bsdName: String) async throws {
        try await unmountWhole(bsdName)
        let d = try disk(bsdName)
        try await perform { DADiskEject(d, DADiskEjectOptions(kDADiskEjectOptionDefault), Self.callback, $0) }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
