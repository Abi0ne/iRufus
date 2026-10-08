import IrufusCore
import SwiftUI
import UniformTypeIdentifiers

struct MainView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var showImporter = false
    @State private var dropTargeted = false
    @State private var advanced: AdvancedAction?

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            Form {
                DeviceSection()
                ImageSection(showImporter: $showImporter)
                if model.report != nil {
                    ChecksumSection()
                    OptionsSection()
                    if model.windowsOptionsAvailable {
                        WindowsSection()
                    }
                }
            }
            .formStyle(.grouped)
            .disabled(model.isBusy)
            Divider()
            StatusBar(advanced: $advanced)
                .padding(12)
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.item], allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                model.selectImage(url)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first, url.isFileURL, !model.isBusy else { return false }
            model.selectImage(url)
            return true
        } isTargeted: { dropTargeted = $0 }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .padding(4)
                    .accessibilityHidden(true)
            }
        }
        .sheet(item: $model.pending) { op in
            ConfirmSheet(operation: op)
        }
        .sheet(item: $advanced) { action in
            AdvancedSheet(action: action)
        }
    }
}

// MARK: - Device

struct DeviceSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Section {
            if !model.diskArbitrationAvailable {
                Label("Disk access is not available on this system.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            }
            HStack {
                Picker("Device", selection: $model.selectedDeviceID) {
                    Text("Select a device…").tag(String?.none)
                    ForEach(model.selectableDevices) { d in
                        Text(deviceLine(d)).tag(Optional(d.id))
                    }
                }
                .accessibilityHint(Text("Only removable devices that can be safely identified are listed."))
                Button {
                    model.refreshDevices()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh the device list (⌘R)")
                .accessibilityLabel(Text("Refresh Devices"))
                if let d = model.selectedDevice, d.facts.ejectable {
                    Button {
                        model.eject(d)
                    } label: {
                        Image(systemName: "eject")
                    }
                    .help("Unmount and eject the selected device")
                    .accessibilityLabel(Text("Eject"))
                }
            }
            if model.selectableDevices.isEmpty {
                Text("No suitable device found. Insert a USB flash drive or SD card.")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
            if let d = model.selectedDevice {
                DeviceDetails(device: d)
            }
            if !model.excludedDevices.isEmpty {
                DisclosureGroup {
                    ForEach(model.excludedDevices) { d in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(deviceLine(d))
                            Text(exclusionText(d.exclusion))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                } label: {
                    Text("Hidden devices (\(model.excludedDevices.count))")
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Device")
        }
    }

    func deviceLine(_ d: DiskDevice) -> String {
        "\(d.facts.displayName) — \(model.formatBytes(d.facts.size)) — \(d.facts.bsdName)"
    }
}

func exclusionText(_ e: DeviceExclusion?) -> String {
    switch e {
    case .none: return ""
    case .unidentified: return String(localized: "Not identified with enough certainty")
    case .internalDisk: return String(localized: "Internal disk")
    case .bootDisk: return String(localized: "Contains the startup volume or your home folder")
    case .sourceImageDisk: return String(localized: "Contains the selected image")
    case .synthesized: return String(localized: "Virtual APFS container")
    case .readOnly: return String(localized: "Read-only (check the lock switch)")
    case .unsupportedConnection: return String(localized: "Connection type not supported (only USB and SD)")
    case .usbHardDrive: return String(localized: "USB hard drive (enable in Settings)")
    case .diskImage: return String(localized: "Attached disk image (enable in Settings)")
    case .userExcluded: return String(localized: "Excluded by you (see Settings)")
    }
}

struct DeviceDetails: View {
    @Environment(AppModel.self) private var model
    let device: DiskDevice

    var body: some View {
        let f = device.facts
        DisclosureGroup("Details") {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                row("Identifier", "/dev/\(f.bsdName)")
                row("Capacity", "\(model.formatBytes(f.size)) (\(f.size) bytes)")
                if let v = f.vendor { row("Manufacturer", v) }
                if let m = f.model { row("Model", m) }
                row("Connection", f.connection ?? "—")
                row("Block size", "\(f.blockSize) bytes")
                row("Removable media", f.removable ? String(localized: "Yes") : String(localized: "No"))
                if let c = f.contentType { row("Partition scheme", c) }
            }
            .font(.callout)
            if !device.partitions.isEmpty {
                Text("Partitions").font(.callout.bold()).padding(.top, 4)
                ForEach(device.partitions) { p in
                    Text("\(p.bsdName): \(p.volumeName ?? p.content ?? "—") \(p.fileSystem.map { "(\($0))" } ?? "") \(model.formatBytes(p.size))\(p.mountPoint.map { " — \($0)" } ?? "")")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Button("Never show this device again") {
                model.excludeSelectedDevice()
            }
            .font(.callout)
        }
    }

    @ViewBuilder
    func row(_ key: LocalizedStringKey, _ value: String) -> some View {
        GridRow {
            Text(key).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }
}

// MARK: - Image

struct ImageSection: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @Binding var showImporter: Bool

    var body: some View {
        Section {
            HStack {
                VStack(alignment: .leading) {
                    Text(model.imageURL?.lastPathComponent ?? String(localized: "No image selected"))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if model.imageURL == nil {
                        Text("Choose or drop an ISO, a disk image (.img, .raw, .vhd) or a compressed image (.gz, .xz, .zst, .bz2, .zip).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Menu("Download") {
                    Button("Windows 11 (official Microsoft page)") {
                        openURL(URL(string: "https://www.microsoft.com/software-download/windows11")!)
                    }
                    Button("Windows 10 (official Microsoft page)") {
                        openURL(URL(string: "https://www.microsoft.com/software-download/windows10ISO")!)
                    }
                }
                .fixedSize()
                .help("Opens the official download page in your browser. Compare the SHA-256 published there with the one computed here.")
                Button("Choose…") { showImporter = true }
                    .keyboardShortcut("o", modifiers: [.command])
            }
            if model.analyzing {
                ProgressView("Analysing image…")
                    .controlSize(.small)
            }
            if let err = model.analysisError {
                Label(err, systemImage: "xmark.octagon").foregroundStyle(.red)
            }
            if let r = model.report {
                ImageSummary(report: r)
            }
        } header: {
            Text("Boot selection")
        }
    }
}

struct ImageSummary: View {
    @Environment(AppModel.self) private var model
    let report: ImageReport

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
            GridRow {
                Text("Type").foregroundStyle(.secondary)
                Text(typeText)
            }
            if let l = report.label {
                GridRow {
                    Text("Label").foregroundStyle(.secondary)
                    Text(l).textSelection(.enabled)
                }
            }
            GridRow {
                Text("Size").foregroundStyle(.secondary)
                Text(sizeText)
            }
            if !report.architectures.isEmpty {
                GridRow {
                    Text("Architecture").foregroundStyle(.secondary)
                    Text(report.architectures.map(archName).joined(separator: ", "))
                }
            }
            if let w = report.iso?.windows, let img = w.wim?.images, !img.isEmpty {
                GridRow {
                    Text("Editions").foregroundStyle(.secondary)
                    Text(img.prefix(6).map(\.name).joined(separator: ", ") + (img.count > 6 ? "…" : ""))
                        .lineLimit(3)
                }
            }
            if let hint = report.iso?.linux?.distroHint {
                GridRow {
                    Text("Distribution").foregroundStyle(.secondary)
                    Text(hint).lineLimit(2)
                }
            }
            GridRow {
                Text("Write modes").foregroundStyle(.secondary)
                Text(report.modes.isEmpty ? String(localized: "None") : report.modes.map(modeName).joined(separator: ", "))
            }
        }
        .font(.callout)
        ForEach(report.notes, id: \.self) { note in
            NoteRow(note: note)
        }
    }

    var typeText: String {
        var parts: [String] = []
        switch report.kind {
        case .iso:
            if report.iso?.windows != nil {
                parts.append(String(localized: "Windows installation ISO"))
            } else if report.iso?.linux != nil {
                parts.append(String(localized: "Linux ISO"))
            } else {
                parts.append(String(localized: "ISO image"))
            }
            if report.iso?.isohybrid == true { parts.append(String(localized: "hybrid (DD capable)")) }
        case .diskImage:
            parts.append(String(localized: "Disk image"))
            if let s = report.layout?.scheme { parts.append(s == .gpt ? "GPT" : "MBR") }
        }
        if report.source.container.kind != "raw" {
            parts.append(String(localized: "compressed: \(report.source.container.kind)"))
        }
        return parts.joined(separator: ", ")
    }

    var sizeText: String {
        let file = model.formatBytes(report.source.fileSize)
        if let s = report.imageSize, s != report.source.fileSize {
            return String(localized: "\(file) file, \(model.formatBytes(s)) uncompressed")
        }
        if report.source.container.kind != "raw" && report.imageSize == nil {
            return String(localized: "\(file) file, uncompressed size unknown")
        }
        return file
    }
}

func archName(_ a: String) -> String {
    switch a {
    case "x64": "x86-64"
    case "ia32": "x86 (32-bit)"
    case "arm64": "ARM64"
    case "arm": "ARM (32-bit)"
    case "riscv64": "RISC-V 64"
    case "loongarch64": "LoongArch 64"
    default: a
    }
}

func modeName(_ m: WriteMode) -> String {
    switch m {
    case .dd: String(localized: "DD image (bit-for-bit copy)")
    case .isoExtract: String(localized: "ISO image (extract files to FAT32)")
    }
}

func targetName(_ t: String) -> String {
    switch t {
    case "bios": return String(localized: "BIOS / legacy (CSM)")
    case "uefi": return String(localized: "UEFI")
    default:
        if t.hasPrefix("uefi-") { return String(localized: "UEFI \(archName(String(t.dropFirst(5))))") }
        return t
    }
}

struct NoteRow: View {
    let note: Note

    var body: some View {
        Label {
            Text(noteText(note)).font(.callout)
        } icon: {
            switch note.level {
            case .info: Image(systemName: "info.circle").foregroundStyle(.blue)
            case .warning: Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
            case .error: Image(systemName: "xmark.octagon").foregroundStyle(.red)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

func noteText(_ n: Note) -> String {
    let a = n.args
    switch n.code {
    case "noBootSignature": return String(localized: "This image has no boot signature: it can be written, but it will not boot.")
    case "compressedIsoDdOnly": return String(localized: "Compressed ISO: only DD mode is possible. Decompress it to use ISO mode.")
    case "notHybridIso": return String(localized: "This ISO is not hybrid: DD mode would not produce a bootable USB drive.")
    case "efiOnlyInElTorito": return String(localized: "The UEFI loader exists only inside the El Torito image; ISO mode is not supported for this image.")
    case "noEfiLoader": return String(localized: "No UEFI boot loader (/EFI/BOOT/BOOT*.EFI) found: ISO mode would not boot.")
    case "fileTooLargeForFat32":
        let size = UInt64(a.count > 1 ? a[1] : "0") ?? 0
        return String(localized: "\(a.first ?? "?") is \(Format.bytes(size)): FAT32 cannot store files over 4 GB, so ISO mode is not available.")
    case "wimWillBeSplit": return String(localized: "install.wim is larger than 4 GB: it will be split into .swm parts that Windows Setup reads natively.")
    case "existingAnswerFile": return String(localized: "The ISO already contains an answer file: Windows customisation is disabled.")
    case "isoModeUefiOnly": return String(localized: "ISO mode creates UEFI-only media (no BIOS/CSM boot): the target PC must boot in UEFI mode.")
    case "ddRecommendedLinux": return String(localized: "DD mode is recommended for this Linux image: it keeps BIOS and UEFI boot exactly as designed by the distribution.")
    case "noUsableMode": return String(localized: "This image cannot be made bootable with the methods available in iRufus.")
    case "sizeUnknown": return String(localized: "The uncompressed size is not known in advance; space is checked while writing.")
    case "udfFallback": return String(localized: "The UDF file system could not be read; the ISO 9660 view is used instead.")
    case "symlinksResolved": return String(localized: "\(a.first ?? "0") symbolic links were replaced by file copies (FAT32 has no links).")
    case "wimUnreadable": return String(localized: "The Windows image metadata could not be read.")
    default: return n.code
    }
}

// MARK: - Checksums

struct ChecksumSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Section {
            HStack {
                ForEach(HashAlgorithm.allCases) { a in
                    Toggle(a.displayName, isOn: Binding(
                        get: { model.hash.algorithms.contains(a) },
                        set: { on in
                            if on { model.hash.algorithms.insert(a) } else { model.hash.algorithms.remove(a) }
                        }))
                        .toggleStyle(.checkbox)
                }
                Spacer()
                if model.hash.running {
                    Button("Stop") { model.cancelHashes() }
                } else {
                    Button("Compute") { model.computeHashes() }
                        .disabled(model.hash.algorithms.isEmpty)
                }
            }
            if model.hash.running {
                ProgressView(value: model.hash.progress ?? 0)
                    .accessibilityLabel(Text("Checksum progress"))
            }
            if let r = model.hash.result {
                ForEach(HashAlgorithm.allCases) { a in
                    if let v = r.value(for: a) {
                        LabeledContent(a.displayName) {
                            Text(v).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        }
                    }
                }
            }
            TextField("Expected checksum (paste from the official site)", text: $model.hash.expected)
                .font(.system(.body, design: .monospaced))
            comparison
            Text("A matching checksum proves the file is intact (integrity). It proves authenticity only if the expected value comes from the publisher's official, secure page or a verified signature.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("Checksum")
        }
    }

    @ViewBuilder
    var comparison: some View {
        switch model.checksumComparison {
        case .empty:
            EmptyView()
        case .unparseable:
            Label("Not a valid MD5, SHA-1, SHA-256 or SHA-512 value", systemImage: "questionmark.circle").foregroundStyle(.orange)
        case .notComputed(let a):
            Label("Compute \(a.displayName) to compare", systemImage: "info.circle").foregroundStyle(.secondary)
        case .match(let a):
            Label("\(a.displayName) matches", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
        case .mismatch(let a):
            Label("\(a.displayName) does NOT match: do not use this image", systemImage: "xmark.seal.fill").foregroundStyle(.red)
        }
    }
}
