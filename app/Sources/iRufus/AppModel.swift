import AppKit
import Foundation
import IrufusCore
import Observation

/// A destructive (or read-only) operation waiting for user confirmation.
struct PendingOperation: Identifiable {
    enum Kind: Equatable {
        /// Write the image; optionally run a destructive bad-blocks test first (Rufus option).
        case write(badBlocksPasses: UInt32?)
        case badBlocks(passes: UInt32)
        case zero
        case save(URL, Engine.SaveFormat)

        var isDestructive: Bool {
            if case .save = self { return false }
            return true
        }
    }

    let id = UUID()
    let kind: Kind
    let facts: DiskFacts
    let identity: DiskIdentity
    let level: ConfirmationLevel
}

enum OperationState: Equatable {
    case idle
    case running(title: String, progress: EngineProgress?)
    case succeeded(String)
    case failed(String)
    case cancelled
}

struct HashState: Equatable {
    var algorithms: Set<HashAlgorithm> = [.sha256]
    var running = false
    var progress: Double?
    var result: HashResult?
    var resultPath: String?
    var expected = ""
}

@MainActor
@Observable
final class AppModel {
    // Devices
    private(set) var devices: [DiskDevice] = []
    var selectedDeviceID: String? {
        didSet { if oldValue != selectedDeviceID { deviceSelectionChanged() } }
    }
    private(set) var diskArbitrationAvailable = true

    // Image
    private(set) var imageURL: URL?
    private(set) var report: ImageReport?
    private(set) var analyzing = false
    private(set) var analysisError: String?
    var options: WriteOptions? {
        didSet { optionsChanged(old: oldValue) }
    }
    private(set) var fat32: Fat32Options?
    private(set) var accountNameError: String?

    // Checksums
    var hash = HashState()
    var showChecksum = false

    // Rufus-style advanced format options and the Windows dialog shown after START
    var badBlocksBeforeWrite = false
    var badBlocksPasses: UInt32 = 1
    var showWindowsDialog = false
    private(set) var statusMessage = ""

    // Operation
    private(set) var operation: OperationState = .idle
    var pending: PendingOperation?
    private(set) var logEntries: [LogEntry] = []
    private(set) var lastBadBlocks: BadBlocksReport?

    var settings: AppSettings {
        didSet {
            settings.save()
            applyPolicy()
        }
    }

    @ObservationIgnored private var diskService: DiskService?
    @ObservationIgnored private let log = LogStore()
    @ObservationIgnored private var cancelHandle: CancelHandle?
    @ObservationIgnored private var hashCancel: CancelHandle?
    @ObservationIgnored private var analysisGeneration = 0

    static let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"

    init() {
        settings = AppSettings.load()
        hash.algorithms = settings.defaultHashes
        log.onAppend = { [weak self] e in self?.logEntries.append(e) }
        log.add("iRufus \(Self.appVersion), engine \(Engine.version) (ABI \(Engine.abiVersion)), macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        guard Engine.abiVersion == 1 else {
            log.add("Engine ABI mismatch", level: .error)
            operation = .failed(String(localized: "The storage engine does not match this version of iRufus."))
            return
        }
        if let ds = DiskService() {
            diskService = ds
            ds.onChange = { [weak self] list in self?.devicesChanged(list) }
            applyPolicy()
        } else {
            diskArbitrationAvailable = false
            log.add("Disk Arbitration session could not be created", level: .error)
        }
    }

    // MARK: - Derived state

    var isBusy: Bool {
        if case .running = operation { return true }
        return false
    }

    var selectedDevice: DiskDevice? {
        devices.first { $0.id == selectedDeviceID && $0.isSelectable }
    }

    var selectableDevices: [DiskDevice] { devices.filter(\.isSelectable) }
    var excludedDevices: [DiskDevice] { devices.filter { !$0.isSelectable } }

    var planIssues: [PlanIssue] {
        WritePlanner.issues(report: report, device: selectedDevice, options: options, accountNameValid: accountNameError == nil)
    }

    var canStart: Bool { !isBusy && !analyzing && planIssues.isEmpty }

    var windowsOptionsAvailable: Bool {
        guard let report, let options else { return false }
        return WritePlanner.windowsOptionsAvailable(report, mode: options.mode)
    }

    func formatBytes(_ n: UInt64) -> String { Format.bytes(n, binary: settings.binaryUnits) }

    // MARK: - Devices

    private func applyPolicy() {
        guard let ds = diskService else { return }
        var p = EligibilityPolicy()
        p.showUSBHardDrives = settings.showUSBHardDrives
        p.showDiskImages = settings.showDiskImages
        p.excludedIdentities = Set(settings.excludedDevices.keys)
        if let path = imageURL?.path, let bsd = DiskService.bsdNameOfVolume(containing: path) {
            p.sourceBSDNames = [bsd]
        }
        ds.policy = p
    }

    func refreshDevices() {
        diskService?.refresh()
        log.add("Device list refreshed")
    }

    private func devicesChanged(_ list: [DiskDevice]) {
        let before = Set(devices.filter(\.isSelectable).map(\.id))
        devices = list
        if !isBusy {
            let n = list.filter(\.isSelectable).count
            statusMessage = n == 1 ? String(localized: "1 device found") : String(localized: "\(n) devices found")
        }
        let after = Set(list.filter(\.isSelectable).map(\.id))
        for id in after.subtracting(before) {
            if let d = list.first(where: { $0.id == id }) {
                log.add("Device available: \(d.facts.displayName) (\(id), \(Format.bytes(d.facts.size)), \(d.facts.connection ?? "?"))")
            }
        }
        if let sel = selectedDeviceID, !after.contains(sel) {
            log.add("Selected device \(sel) is no longer available", level: .warning)
            selectedDeviceID = nil
        }
    }

    private func deviceSelectionChanged() {
        updateFat32Options()
    }

    func excludeSelectedDevice() {
        guard let d = selectedDevice else { return }
        settings.excludedDevices[d.facts.identityKey] = "\(d.facts.displayName) — \(Format.bytes(d.facts.size))"
        log.add("Device \(d.facts.displayName) added to the exclusion list")
        selectedDeviceID = nil
    }

    func eject(_ device: DiskDevice) {
        guard let ds = diskService else { return }
        Task {
            do {
                try await ds.eject(device.facts.bsdName)
                log.add("Ejected \(device.facts.bsdName)")
            } catch {
                let e = error as? DiskService.DiskOperationError
                log.add("Eject of \(device.facts.bsdName) failed: \(e?.message ?? String(e?.status ?? -1))", level: .error)
                operation = .failed(String(localized: "The device could not be ejected: \(e?.message ?? String(localized: "it is in use"))"))
            }
        }
    }

    // MARK: - Image

    func selectImage(_ url: URL) {
        guard !isBusy else { return }
        imageURL = url
        report = nil
        options = nil
        analysisError = nil
        hash.result = nil
        hash.resultPath = nil
        analyzing = true
        applyPolicy()
        analysisGeneration += 1
        let generation = analysisGeneration
        let path = url.path
        log.add("Analysing \(path)")
        Task.detached(priority: .userInitiated) {
            let result = Result { try Engine.analyze(path: path) }
            await MainActor.run { self.analysisFinished(result, generation: generation) }
        }
    }

    private func analysisFinished(_ result: Result<ImageReport, Error>, generation: Int) {
        guard generation == analysisGeneration else { return }
        analyzing = false
        switch result {
        case .success(let r):
            report = r
            options = WritePlanner.defaults(for: r, verify: settings.verifyAfterWrite)
            log.add("Image: \(r.kind.rawValue), container \(r.source.container.kind), modes \(r.modes.map(\.rawValue)), targets DD \(r.ddTargets) / ISO \(r.extractTargets)")
            for n in r.notes {
                log.add("Note [\(n.level.rawValue)] \(n.code) \(n.args)", level: n.level == .error ? .error : n.level == .warning ? .warning : .info)
            }
        case .failure(let e):
            analysisError = Self.describe(e)
            log.add("Analysis failed: \(Self.diagnostic(e))", level: .error)
        }
    }

    private func optionsChanged(old: WriteOptions?) {
        if old?.scheme != options?.scheme || old?.mode != options?.mode {
            updateFat32Options()
        }
        if old?.wue.accountName != options?.wue.accountName || old?.wue.createLocalAccount != options?.wue.createLocalAccount {
            validateAccountName()
        }
    }

    private func updateFat32Options() {
        guard let d = selectedDevice, let o = options, o.mode == .isoExtract else {
            fat32 = nil
            return
        }
        fat32 = try? Engine.fat32Options(deviceBytes: d.facts.size, blockSize: d.facts.blockSize, scheme: o.scheme)
        if let f = fat32, let c = options?.clusterSize, !f.valid.contains(c) {
            options?.clusterSize = nil
        }
    }

    private func validateAccountName() {
        guard let o = options, o.wue.createLocalAccount else {
            accountNameError = nil
            return
        }
        do {
            _ = try Engine.sanitizeAccountName(o.wue.accountName)
            accountNameError = nil
        } catch {
            accountNameError = String(localized: "This name cannot be used for a Windows account.")
        }
    }

    func answerFilePreview() -> AnswerFilePreview? {
        guard let report, let options else { return nil }
        let req = WritePlanner.request(options: options, report: report, locale: LocaleSettings.current())
        guard let wue = req.wue else { return nil }
        return try? Engine.answerFilePreview(wue)
    }

    // MARK: - Checksums

    func computeHashes() {
        guard let url = imageURL, !hash.running else { return }
        hash.running = true
        hash.progress = 0
        hash.result = nil
        let algos = hash.algorithms.isEmpty ? [.sha256] : hash.algorithms
        let cancel = CancelHandle()
        hashCancel = cancel
        let path = url.path
        log.add("Computing \(algos.map(\.displayName).sorted().joined(separator: ", ")) of \(path)")
        let observer = EngineObserver(onProgress: { p in
            DispatchQueue.main.async { self.hash.progress = p.fraction }
        }, onLog: { _ in })
        Task.detached(priority: .userInitiated) {
            let result = Result { try Engine.hashFile(path: path, algorithms: algos, observer: observer, cancel: cancel) }
            await MainActor.run {
                self.hash.running = false
                self.hash.progress = nil
                self.hashCancel = nil
                switch result {
                case .success(let r):
                    self.hash.result = r
                    self.hash.resultPath = path
                    for a in HashAlgorithm.allCases {
                        if let v = r.value(for: a) { self.log.add("\(a.displayName): \(v)") }
                    }
                case .failure(let e):
                    if (e as? EngineError)?.code != .cancelled {
                        self.log.add("Checksum failed: \(Self.diagnostic(e))", level: .error)
                    }
                }
            }
        }
    }

    func cancelHashes() {
        hashCancel?.cancel()
    }

    enum ChecksumComparison: Equatable {
        case empty
        case unparseable
        case notComputed(HashAlgorithm)
        case match(HashAlgorithm)
        case mismatch(HashAlgorithm)
    }

    var checksumComparison: ChecksumComparison {
        let input = hash.expected.trimmingCharacters(in: .whitespacesAndNewlines)
        if input.isEmpty { return .empty }
        guard let parsed = Engine.parseChecksum(input) else { return .unparseable }
        guard let actual = hash.result?.value(for: parsed.algorithm) else { return .notComputed(parsed.algorithm) }
        return actual.lowercased() == parsed.digest.lowercased() ? .match(parsed.algorithm) : .mismatch(parsed.algorithm)
    }

    // MARK: - Operations

    /// START: like Rufus, Windows images first show the customisation dialog.
    func startPressed() {
        guard canStart else { return }
        if windowsOptionsAvailable {
            showWindowsDialog = true
        } else {
            requestWrite()
        }
    }

    func windowsDialogFinished(proceed: Bool) {
        showWindowsDialog = false
        guard proceed else { return }
        requestWrite()
    }

    func requestWrite() {
        guard canStart, let d = selectedDevice else { return }
        let kind = PendingOperation.Kind.write(badBlocksPasses: badBlocksBeforeWrite ? badBlocksPasses : nil)
        pending = PendingOperation(kind: kind, facts: d.facts, identity: DiskIdentity(d.facts), level: ConfirmationLevel.required(for: d.facts))
    }

    func requestAdvanced(_ kind: PendingOperation.Kind) {
        guard !isBusy, let d = selectedDevice else { return }
        if case .save(let url, _) = kind,
           let bsd = DiskService.bsdNameOfVolume(containing: url.deletingLastPathComponent().path),
           d.facts.descendantBSDNames.union([d.facts.bsdName]).contains(bsd) {
            operation = .failed(String(localized: "The image cannot be saved on the device being read."))
            return
        }
        let level: ConfirmationLevel = kind.isDestructive ? ConfirmationLevel.required(for: d.facts) : .standard
        pending = PendingOperation(kind: kind, facts: d.facts, identity: DiskIdentity(d.facts), level: level)
    }

    func cancelOperation() {
        cancelHandle?.cancel()
        log.add("Cancellation requested", level: .warning)
    }

    func confirm(_ op: PendingOperation) {
        pending = nil
        guard let ds = diskService else { return }
        let request: WriteRequest?
        let imagePath = imageURL?.path
        if case .write = op.kind {
            guard let report, let options, let imagePath else { return }
            request = WritePlanner.request(options: options, report: report, locale: LocaleSettings.current())
            if let name = request?.wue?.localAccount { log.registerSecret(name) }
            if let wue = request?.wue {
                log.add("Windows options: bypass=\(wue.bypassRequirements) noMSA=\(wue.noOnlineAccount) localAccount=\(wue.localAccount != nil) privacy=\(wue.disableDataCollection) locale=\(wue.locale != nil) noBitLocker=\(wue.disableBitlocker)")
            }
            log.add("Write \(imagePath) → /dev/\(op.identity.bsdName), mode \(request!.mode.rawValue), scheme \(request?.scheme?.rawValue ?? "-"), verify \(request!.verify)")
        } else {
            request = nil
        }
        let title = Self.title(for: op.kind)
        operation = .running(title: title, progress: nil)
        let cancel = CancelHandle()
        cancelHandle = cancel
        let bsd = op.identity.bsdName
        Task {
            defer {
                ds.allowMounts()
                cancelHandle = nil
                log.clearSecrets()
            }
            // 1. The disk must still be the one the user confirmed.
            guard let now = ds.currentFacts(bsdName: bsd), DiskIdentity(now) == op.identity else {
                fail(String(localized: "The selected device changed or was disconnected. Nothing was written."), diag: "identity check failed before unmount")
                return
            }
            // 2. Unmount and keep macOS from remounting while we work.
            if op.kind.isDestructive { ds.blockMounts(of: bsd) }
            do {
                try await ds.unmountWhole(bsd)
            } catch let e as DiskService.DiskOperationError {
                fail(String(localized: "The device could not be unmounted: \(e.message ?? String(localized: "a volume is in use"))"),
                     diag: "unmount failed with status \(e.status) \(e.message ?? "")")
                return
            } catch {
                fail(Self.describe(error), diag: "\(error)")
                return
            }
            guard let again = ds.currentFacts(bsdName: bsd), DiskIdentity(again) == op.identity else {
                fail(String(localized: "The selected device changed or was disconnected. Nothing was written."), diag: "identity check failed after unmount")
                return
            }
            log.add("Unmounted /dev/\(bsd); requesting access")
            // 3. Privileged descriptor + engine, off the main thread.
            let observer = EngineObserver(onProgress: { p in
                DispatchQueue.main.async {
                    if case .running = self.operation { self.operation = .running(title: title, progress: p) }
                }
            }, onLog: { line in
                DispatchQueue.main.async { self.log.add(line) }
            })
            let prompt = String(localized: "iRufus needs administrator permission to access “\(op.facts.displayName)” (\(Format.bytes(op.facts.size)), /dev/\(bsd)).")
            let kind = op.kind
            let identity = op.identity
            let outcome: Result<String, Error> = await Task.detached(priority: .userInitiated) {
                Result {
                    let fd = try PrivilegeBroker.openDevice(identity, mode: kind.isDestructive ? .readWrite : .readOnly, prompt: prompt)
                    let device = try EngineDevice(fd: fd, expectedSize: identity.size, expectedBlockSize: identity.blockSize)
                    return try Self.execute(kind, device: device, imagePath: imagePath, request: request, observer: observer, cancel: cancel)
                }
            }.value
            // The descriptor is closed here; macOS re-reads the partition table.
            ds.allowMounts()
            switch outcome {
            case .success(let message):
                operation = .succeeded(message)
                statusMessage = message
                log.add(message)
                if kind.isDestructive {
                    try? await Task.sleep(for: .seconds(1))
                    try? await ds.mountWhole(bsd)
                }
            case .failure(let e):
                if (e as? EngineError)?.code == .cancelled {
                    operation = .cancelled
                    statusMessage = String(localized: "Cancelled. The device content is incomplete and must be rewritten or erased.")
                    log.add("Operation cancelled; the device content is incomplete", level: .warning)
                } else if let b = e as? BrokerError, b == .authorizationDenied {
                    operation = .failed(String(localized: "Administrator authorization was cancelled. Nothing was written."))
                    log.add("Authorization cancelled", level: .warning)
                } else {
                    fail(Self.describe(e), diag: Self.diagnostic(e))
                }
            }
            ds.refresh()
        }
    }

    private func fail(_ message: String, diag: String) {
        operation = .failed(message)
        statusMessage = message
        log.add("Operation failed: \(diag)", level: .error)
    }

    nonisolated private static func execute(_ kind: PendingOperation.Kind, device: EngineDevice, imagePath: String?, request: WriteRequest?,
                                            observer: EngineObserver, cancel: CancelHandle) throws -> String {
        switch kind {
        case .write(let passes):
            guard let imagePath, let request else { throw EngineError(code: .invalidArgument, message: "no image") }
            if let passes {
                let r = try Engine.badBlocks(device: device, passes: passes, observer: observer, cancel: cancel)
                if r.badSectors > 0 {
                    throw EngineError(code: .badBlocksFound, message: "\(r.badSectors) bad sectors, fake capacity suspected: \(r.fakeCapacitySuspected)")
                }
            }
            switch try Engine.write(device: device, imagePath: imagePath, request: request, observer: observer, cancel: cancel) {
            case .dd(let s):
                return s.verified
                    ? String(localized: "Done: \(Format.bytes(s.bytesWritten)) written and verified.")
                    : String(localized: "Done: \(Format.bytes(s.bytesWritten)) written (not verified).")
            case .extract(let s):
                var msg = s.verified
                    ? String(localized: "Done: \(s.filesCopied) files copied and verified.")
                    : String(localized: "Done: \(s.filesCopied) files copied (not verified).")
                if !s.wimParts.isEmpty { msg += " " + String(localized: "install.wim was split into \(s.wimParts.count) parts.") }
                if s.answerFile != nil { msg += " " + String(localized: "Windows answer file added.") }
                return msg
            }
        case .zero:
            try Engine.zero(device: device, verify: true, observer: observer, cancel: cancel)
            return String(localized: "Done: the device was overwritten with zeros and verified.")
        case .badBlocks(let passes):
            let r = try Engine.badBlocks(device: device, passes: passes, observer: observer, cancel: cancel)
            if r.fakeCapacitySuspected {
                return String(localized: "Bad blocks check: FAKE CAPACITY SUSPECTED — \(r.badSectors) bad sectors. Do not use this device for important data.")
            }
            return r.badSectors == 0
                ? String(localized: "Bad blocks check: no bad blocks found (\(r.passes) passes).")
                : String(localized: "Bad blocks check: \(r.badSectors) bad sectors found.")
        case .save(let url, let format):
            let s = try Engine.save(device: device, to: url.path, format: format, observer: observer, cancel: cancel)
            return String(localized: "Done: device saved to \(url.lastPathComponent) (SHA-256 \(s.sha256)).")
        }
    }

    static func title(for kind: PendingOperation.Kind) -> String {
        switch kind {
        case .write(let passes): passes == nil ? String(localized: "Writing") : String(localized: "Checking blocks and writing")
        case .zero: String(localized: "Erasing")
        case .badBlocks: String(localized: "Checking for bad blocks")
        case .save: String(localized: "Saving image")
        }
    }

    // MARK: - Errors

    static func diagnostic(_ e: Error) -> String {
        if let e = e as? EngineError { return "engine error \(e.code.rawValue): \(e.message)" }
        if let b = e as? BrokerError { return "broker: \(b)" }
        return "\(e)"
    }

    static func describe(_ e: Error) -> String {
        if let b = e as? BrokerError {
            switch b {
            case .authorizationDenied: return String(localized: "Administrator authorization was cancelled. Nothing was written.")
            case .identityMismatch: return String(localized: "The opened device does not match the selected disk. Nothing was written.")
            default: return String(localized: "Access to the device could not be obtained.")
            }
        }
        guard let e = e as? EngineError else { return e.localizedDescription }
        switch e.code {
        case .io: return String(localized: "Input/output error. The device may be faulty or was removed.")
        case .cancelled: return String(localized: "Cancelled.")
        case .invalidArgument: return String(localized: "Invalid request.")
        case .unsupportedImage: return String(localized: "This image format is not supported.")
        case .corruptImage: return String(localized: "The image is corrupt or truncated.")
        case .insufficientSpace: return String(localized: "The device is too small for this image.")
        case .deviceMismatch: return String(localized: "The opened device does not match the selected disk. Nothing was written.")
        case .deviceGone: return String(localized: "The device was disconnected during the operation.")
        case .verifyFailed: return String(localized: "Verification failed: the data read back differs. The device may be faulty or counterfeit.")
        case .fileTooLarge: return String(localized: "The image contains a file larger than 4 GB that FAT32 cannot store.")
        case .unsupported: return String(localized: "This operation is not supported for this image.")
        case .badBlocksFound: return String(localized: "Bad blocks were found.")
        case .internal: return String(localized: "Internal error. Please export the log and report it.")
        }
    }

    // MARK: - Log

    func exportLog() -> String {
        log.exportText(appVersion: Self.appVersion, engineVersion: Engine.version)
    }

    func clearLog() {
        log.clear()
        logEntries.removeAll()
    }
}
