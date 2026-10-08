import Foundation
@testable import IrufusCore

func usbStick(_ name: String = "disk4", size: UInt64 = 32_000_000_000) -> DiskFacts {
    var f = DiskFacts(bsdName: name, size: size, blockSize: 512)
    f.vendor = "SanDisk"
    f.model = "Ultra"
    f.removable = true
    f.ejectable = true
    f.writable = true
    f.isInternal = false
    f.connection = "USB"
    f.busPath = "IODeviceTree:/usb@1"
    f.major = 1
    f.minor = 12
    f.descendantBSDNames = ["\(name)s1"]
    return f
}

struct EligibilityTests {
    func plainUSBStickIsSelectable() {
        expect(EligibilityPolicy().evaluate(usbStick()) == nil)
    }

    func internalAndBootDisksAreNeverSelectable() {
        var internalDisk = usbStick("disk0")
        internalDisk.isInternal = true
        internalDisk.connection = "PCI-Express"
        expect(EligibilityPolicy().evaluate(internalDisk) == .internalDisk)

        var p = EligibilityPolicy()
        p.protectedBSDNames = ["disk4s1"]
        p.showUSBHardDrives = true
        p.showDiskImages = true
        expect(p.evaluate(usbStick()) == .bootDisk, "an external startup disk must be protected")
    }

    func sourceImageDiskIsExcluded() {
        var p = EligibilityPolicy()
        p.sourceBSDNames = ["disk4s1"]
        expect(p.evaluate(usbStick()) == .sourceImageDisk)
    }

    func incompleteIdentificationIsRejected() {
        var f = usbStick()
        f.major = nil
        expect(EligibilityPolicy().evaluate(f) == .unidentified)
        var g = usbStick("disk4s2")
        g.descendantBSDNames = []
        expect(EligibilityPolicy().evaluate(g) == .unidentified)
        var h = usbStick()
        h.blockSize = 2048
        expect(EligibilityPolicy().evaluate(h) == .unidentified)
        expect(EligibilityPolicy().evaluate(DiskFacts(bsdName: "disk9", size: 0, blockSize: 512)) == .unidentified)
    }

    func optionalCategoriesNeedSettings() {
        var hdd = usbStick()
        hdd.removable = false
        expect(EligibilityPolicy().evaluate(hdd) == .usbHardDrive)
        var p = EligibilityPolicy()
        p.showUSBHardDrives = true
        expect(p.evaluate(hdd) == nil)

        var img = usbStick()
        img.connection = "Disk Image"
        expect(EligibilityPolicy().evaluate(img) == .diskImage)
        p.showDiskImages = true
        expect(p.evaluate(img) == nil)

        var tb = usbStick()
        tb.connection = "PCI-Express"
        expect(p.evaluate(tb) == .unsupportedConnection)

        var ro = usbStick()
        ro.writable = false
        expect(EligibilityPolicy().evaluate(ro) == .readOnly)

        var synth = usbStick()
        synth.isSynthesized = true
        expect(p.evaluate(synth) == .synthesized)

        var excl = EligibilityPolicy()
        excl.excludedIdentities = [usbStick().identityKey]
        expect(excl.evaluate(usbStick()) == .userExcluded)
    }
}

struct ConfirmationTests {
    func smallWellIdentifiedStickNeedsStandardConfirmation() {
        expect(ConfirmationLevel.required(for: usbStick()) == .standard)
    }

    func largeOrAmbiguousDisksNeedTypedIdentifier() {
        let big = usbStick(size: 256_000_000_000)
        expect(ConfirmationLevel.required(for: big) == .typeIdentifier(reasons: [.largeDisk]))
        var anon = usbStick()
        anon.vendor = nil
        anon.model = " "
        anon.removable = false
        expect(ConfirmationLevel.required(for: anon) == .typeIdentifier(reasons: [.noVendorOrModel, .notRemovableMedia]))
    }

    func identityDetectsSwappedDevice() {
        let a = DiskIdentity(usbStick())
        var other = usbStick()
        other.busPath = "IODeviceTree:/usb@2"
        expect(a != DiskIdentity(other))
        expect(a == DiskIdentity(usbStick()))
        expect(a.rawDevicePath == "/dev/rdisk4")
        expect(a.expectedRdev == dev_t((1 << 24) | 12))
    }

    func brokerAcceptsOnlyWholeRawDisks() throws {
        try PrivilegeBroker.validate(rawDevicePath: "/dev/rdisk4")
        for bad in ["/dev/disk4", "/dev/rdisk4s1", "/dev/rdisk4; rm -rf /", "/etc/passwd", "/dev/rdisk", "/dev/../dev/rdisk4"] {
            expectThrows(BrokerError.self) { try PrivilegeBroker.validate(rawDevicePath: bad) }
        }
    }
}

struct LogTests {
    func homeUserAndSecretsAreRemoved() {
        let s = LogStore.redact("Analysing /Users/mario/Downloads/win.iso for Mario Rossi",
                                secrets: ["Mario Rossi"], home: "/Users/mario", user: "mario")
        expect(s == "Analysing ~/Downloads/win.iso for <redacted>")
        let t = LogStore.redact("/Volumes/X/Users/mario/a", home: "/Users/mario", user: "mario")
        expect(t == "/Volumes/X/Users/<user>/a")
    }

    @MainActor func storeAppliesSecretsAndExports() {
        let log = LogStore()
        log.registerSecret("Luigi")
        log.add("account Luigi created")
        expect(log.entries.last?.message == "account <redacted> created")
        expect(log.exportText(appVersion: "1", engineVersion: "2").contains("<redacted>"))
    }
}

/// Exercises the real engine through the C ABI (no devices involved).
struct EngineBridgeTests {
    func tempFile(_ data: Data, ext: String = "img") throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + ext)
        try data.write(to: url)
        return url
    }

    func abiAndVersion() {
        expect(Engine.abiVersion == 1)
        expect(!Engine.version.isEmpty)
    }

    func analyzeDiskImage() throws {
        var bytes = Data(count: 8192)
        bytes[510] = 0x55
        bytes[511] = 0xAA
        bytes[0] = 0xEB
        bytes[446 + 4] = 0x0C
        bytes[446 + 8] = 1
        bytes[446 + 12] = 10
        let url = try tempFile(bytes)
        defer { try? FileManager.default.removeItem(at: url) }
        let r = try Engine.analyze(path: url.path)
        expect(r.kind == .diskImage)
        expect(r.modes == [.dd])
        expect(r.layout?.scheme == .mbr)
        expect(r.ddTargets.contains("bios"))
        expect(r.imageSize == 8192)
    }

    func analyzeErrorsAreTyped() {
        expectThrows(EngineError.self) { _ = try Engine.analyze(path: "/nonexistent/file.iso") }
        do {
            _ = try Engine.analyze(path: "/nonexistent/file.iso")
        } catch let e as EngineError {
            expect(e.code == .io)
        } catch {
            fail("unexpected error \(error)")
        }
    }

    func hashesMatchKnownVectors() throws {
        let url = try tempFile(Data("abc".utf8), ext: "bin")
        defer { try? FileManager.default.removeItem(at: url) }
        let r = try Engine.hashFile(path: url.path, algorithms: Set(HashAlgorithm.allCases), observer: .silent, cancel: CancelHandle())
        expect(r.md5 == "900150983cd24fb0d6963f7d28e17f72")
        expect(r.sha256 == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        expect(Engine.parseChecksum("SHA256 (x.iso) = BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD")?.algorithm == .sha256)
        expect(Engine.parseChecksum("hello") == nil)
    }

    func cancelledHashReportsCancellation() throws {
        let url = try tempFile(Data(count: 1 << 20), ext: "bin")
        defer { try? FileManager.default.removeItem(at: url) }
        let c = CancelHandle()
        c.cancel()
        expectThrows(code: .cancelled) {
            try Engine.hashFile(path: url.path, algorithms: [.sha256], observer: .silent, cancel: c)
        }
    }

    func deviceFromPlainFileWritesAndVerifies() throws {
        let img = try tempFile(Data(repeating: 0xA5, count: 3 << 20))
        let devURL = try tempFile(Data(count: 8 << 20), ext: "dev")
        defer {
            try? FileManager.default.removeItem(at: img)
            try? FileManager.default.removeItem(at: devURL)
        }
        let fd = open(devURL.path, O_RDWR)
        expect(fd >= 0)
        expectThrows(EngineError.self) { _ = try EngineDevice(fd: dup(fd), expectedSize: 1234 * 512, expectedBlockSize: 512) }
        let dev = try EngineDevice(fd: fd, expectedSize: 8 << 20, expectedBlockSize: 512)
        var phases = Set<UInt32>()
        let observer = EngineObserver(onProgress: { phases.insert($0.phase.rawValue) }, onLog: { _ in })
        let s = try Engine.write(device: dev, imagePath: img.path, request: WriteRequest(mode: .dd, verify: true), observer: observer, cancel: CancelHandle())
        guard case .dd(let sum) = s else { fail("wrong summary"); return }
        expect(sum.bytesWritten == 3 << 20)
        expect(sum.verified)
        expect(phases.contains(EnginePhase.writing.rawValue))
        expect(phases.contains(EnginePhase.verifying.rawValue))
    }

    func answerFilePreviewAndAccountNames() throws {
        var o = WueOptions(arch: "amd64")
        expect(try Engine.answerFilePreview(o) == nil)
        o.bypassRequirements = true
        let p = try require(try Engine.answerFilePreview(o))
        expect(p.path == "/Autounattend.xml")
        expect(p.xml.contains("BypassTPMCheck"))
        expectThrows(EngineError.self) { _ = try Engine.sanitizeAccountName("Administrator") }
        expect(try Engine.sanitizeAccountName("ma:rio") == "ma_rio")
    }

    func fat32OptionsForStick() throws {
        let f = try Engine.fat32Options(deviceBytes: 16_000_000_000, blockSize: 512, scheme: .gpt)
        expect(f.default == 8192)
        expect(f.valid.contains(4096))
    }
}

struct PlannerTests {
    func report(modes: [WriteMode], size: UInt64 = 1 << 30, windows: WindowsReport? = nil) -> ImageReport {
        let iso = IsoReport(treeSource: "Udf", hasJoliet: true, hasRockRidge: false, hasUdf: true,
                            elTorito: ElTorito(biosBootable: true, efiBootable: true), isohybrid: modes.contains(.dd),
                            fileCount: 10, dirCount: 2, totalFileBytes: size, largestFile: nil, oversizedFiles: [],
                            efiLoaders: [EfiLoader(path: "/EFI/BOOT/BOOTX64.EFI", arch: "x64")], windows: windows, linux: nil)
        return ImageReport(schemaVersion: 1, path: "/x.iso", fileName: "x.iso",
                           source: SourceInfo(container: SourceContainer(kind: "raw", entry: nil, method: nil), fileSize: size, dataSize: size, sizeIsExact: true),
                           kind: .iso, label: "LABEL", imageSize: size, iso: iso, layout: nil, architectures: ["x64"], modes: modes,
                           recommendedMode: modes.first, ddTargets: ["uefi"], extractTargets: ["uefi-x64"], notes: [])
    }

    let win11 = WindowsReport(installImage: nil, wim: nil, isWindows11: true, needsWimSplit: false, hasBootWim: true,
                              hasExistingAnswerFile: false, unattendArch: "amd64")

    func issuesBlockInconsistentConfigurations() {
        let dev = DiskDevice(facts: usbStick(size: 512 << 20), partitions: [], exclusion: nil)
        let r = report(modes: [.isoExtract], size: 1 << 30)
        let o = WritePlanner.defaults(for: r, verify: true)!
        expect(WritePlanner.issues(report: r, device: dev, options: o).contains { if case .imageLargerThanDevice = $0 { true } else { false } })
        expect(WritePlanner.issues(report: r, device: nil, options: o).contains(.noDevice))
        var dd = o
        dd.mode = .dd
        expect(WritePlanner.issues(report: r, device: dev, options: dd).contains(.modeUnavailable))
        let big = DiskDevice(facts: usbStick(), partitions: [], exclusion: nil)
        expect(WritePlanner.issues(report: r, device: big, options: o).isEmpty)
        let excluded = DiskDevice(facts: usbStick(), partitions: [], exclusion: .bootDisk)
        expect(WritePlanner.issues(report: r, device: excluded, options: o).contains(.deviceNotSelectable(.bootDisk)))
    }

    func windowsRequestOnlyContainsApplicableOptions() {
        let r = report(modes: [.isoExtract], windows: win11)
        var o = WritePlanner.defaults(for: r, verify: true)!
        expect(o.wueEnabled)
        o.wue.createLocalAccount = true
        o.wue.accountName = "  "
        let req = WritePlanner.request(options: o, report: r, locale: nil)
        expect(req.scheme == .gpt)
        expect(req.wue?.bypassRequirements == true)
        expect(req.wue?.localAccount == nil, "blank names are not sent")
        expect(req.label == "LABEL")

        var win10 = win11
        win10 = WindowsReport(installImage: nil, wim: nil, isWindows11: false, needsWimSplit: false, hasBootWim: true,
                              hasExistingAnswerFile: false, unattendArch: "amd64")
        let r10 = report(modes: [.isoExtract], windows: win10)
        var o10 = WritePlanner.defaults(for: r10, verify: true)!
        o10.wue.bypassRequirements = true
        expect(WritePlanner.request(options: o10, report: r10, locale: nil).wue?.bypassRequirements == false)

        var dd = o
        dd.mode = .dd
        expect(WritePlanner.request(options: dd, report: report(modes: [.dd, .isoExtract], windows: win11), locale: nil).wue == nil)
    }
}
