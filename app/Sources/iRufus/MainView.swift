import IrufusCore
import SwiftUI
import UniformTypeIdentifiers

/// Main window, laid out like Rufus: "Drive Properties", "Format Options", "Status".
struct MainView: View {
    @Environment(AppModel.self) private var model
    @State private var showImporter = false
    @State private var dropTargeted = false
    @State private var advanced: AdvancedAction?
    @State private var showAbout = false

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle("Drive Properties")
                DriveOptions(showImporter: $showImporter)
                SectionTitle("Format Options")
                    .padding(.top, 6)
                FormatOptions()
                SectionTitle("Status")
                    .padding(.top, 6)
                StatusBarBig()
                BottomButtons(advanced: $advanced, showAbout: $showAbout)
                    .padding(.top, 4)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 10)
            FooterBar()
        }
        .frame(width: 500)
        .fixedSize(horizontal: false, vertical: true)
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
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .padding(3)
                    .accessibilityHidden(true)
            }
        }
        .sheet(item: $model.pending) { op in ConfirmSheet(operation: op) }
        .sheet(item: $advanced) { action in AdvancedSheet(action: action) }
        .sheet(isPresented: $model.showChecksum) { ChecksumSheet() }
        .sheet(isPresented: $model.download.showSheet) { DownloadSheet() }
        .sheet(isPresented: $model.showWindowsDialog) { WindowsDialog() }
        .sheet(isPresented: $showAbout) { AboutSheet() }
    }
}

// MARK: - Building blocks

/// Large heading followed by a horizontal rule, as in Rufus.
struct SectionTitle: View {
    let title: LocalizedStringKey
    init(_ title: LocalizedStringKey) { self.title = title }

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Rectangle()
                .fill(Color.primary.opacity(0.8))
                .frame(height: 1.5)
        }
    }
}

/// Caption above a control.
struct Field<Content: View>: View {
    let label: LocalizedStringKey
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.callout)
            content
        }
    }
}

/// Disclosure row "▸ Show advanced …" like Rufus.
struct AdvancedToggle: View {
    let show: LocalizedStringKey
    let hide: LocalizedStringKey
    @Binding var expanded: Bool

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.caption.weight(.bold))
                Text(expanded ? hide : show)
            }
        }
        .buttonStyle(.plain)
        .accessibilityValue(Text(expanded ? "Expanded" : "Collapsed"))
    }
}

// MARK: - Drive properties

struct DriveOptions: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @Binding var showImporter: Bool
    @AppStorage("showAdvancedDrive") private var showAdvanced = false

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 10) {
            Field(label: "Device") {
                Picker("Device", selection: $model.selectedDeviceID) {
                    if model.selectableDevices.isEmpty {
                        Text("No suitable device found").tag(String?.none)
                    } else {
                        Text("Select a device…").tag(String?.none)
                    }
                    ForEach(model.selectableDevices) { d in
                        Text(deviceLine(d)).tag(Optional(d.id))
                    }
                }
                .labelsHidden()
                .disabled(model.isBusy)
                .accessibilityHint(Text("Only removable devices that can be safely identified are listed."))
            }

            Field(label: "Boot selection") {
                HStack(spacing: 8) {
                    Text(model.imageURL?.lastPathComponent ?? String(localized: "No image selected"))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(model.imageURL == nil ? .secondary : .primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: .controlBackgroundColor)))
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.secondary.opacity(0.35)))
                        .help(model.imageURL?.path ?? "")
                    Button {
                        model.showChecksum = true
                    } label: {
                        Image(systemName: "checkmark.circle")
                            .font(.title3)
                    }
                    .buttonStyle(.borderless)
                    .disabled(model.imageURL == nil || model.isBusy)
                    .help("Compute the image checksums (MD5, SHA-1, SHA-256, SHA-512)")
                    .accessibilityLabel(Text("Checksum"))
                    Menu {
                        Button("Select…") { showImporter = true }
                        Divider()
                        Button("Download Ubuntu, SystemRescue, FreeDOS…") { model.openDownloads() }
                        Divider()
                        Button("Download Windows 11 (official Microsoft page)") {
                            openURL(URL(string: "https://www.microsoft.com/software-download/windows11")!)
                        }
                        Button("Download Windows 10 (official Microsoft page)") {
                            openURL(URL(string: "https://www.microsoft.com/software-download/windows10ISO")!)
                        }
                    } label: {
                        Text("SELECT")
                    } primaryAction: {
                        showImporter = true
                    }
                    .menuStyle(.borderedButton)
                    .fixedSize()
                    .disabled(model.isBusy)
                    .keyboardShortcut("o", modifiers: [.command])
                }
            }
            if model.analyzing {
                ProgressView("Analysing image…").controlSize(.small)
            }
            if let err = model.analysisError {
                Label(err, systemImage: "xmark.octagon").foregroundStyle(.red).font(.callout)
            }
            if let report = model.report {
                ImageNotes(report: report)
            }

            if let report = model.report, let options = model.options {
                Field(label: "Image option") {
                    Picker("Image option", selection: Binding(get: { options.mode }, set: { model.options?.mode = $0 })) {
                        ForEach(report.modes, id: \.self) { m in
                            Text(imageOptionName(m, report: report)).tag(m)
                        }
                    }
                    .labelsHidden()
                    .disabled(model.isBusy || report.modes.count < 2)
                    .help("DD copies the image bit for bit. ISO mode creates a FAT32 partition and copies the files, so the drive stays usable for data.")
                }
            }

            HStack(alignment: .top, spacing: 14) {
                Field(label: "Partition scheme") {
                    Picker("Partition scheme", selection: schemeBinding) {
                        if isDD {
                            Text(ddSchemeName).tag(PartitionScheme?.none)
                        } else {
                            Text("GPT").tag(Optional(PartitionScheme.gpt))
                            Text("MBR").tag(Optional(PartitionScheme.mbr))
                        }
                    }
                    .labelsHidden()
                    .disabled(model.isBusy || isDD || model.options == nil)
                    .help("GPT: recommended for UEFI PCs made after 2012 and for disks over 2 TB.")
                }
                Field(label: "Target system") {
                    HStack(spacing: 4) {
                        Picker("Target system", selection: .constant(0)) {
                            Text(targetText).tag(0)
                        }
                        .labelsHidden()
                        .disabled(true)
                        Button {
                        } label: {
                            Text("?").font(.callout.bold())
                        }
                        .buttonStyle(.borderless)
                        .help(targetHelp)
                        .accessibilityLabel(Text(targetHelp))
                    }
                }
            }

            AdvancedToggle(show: "Show advanced drive properties", hide: "Hide advanced drive properties", expanded: $showAdvanced)
            if showAdvanced {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("List USB hard drives", isOn: $model.settings.showUSBHardDrives)
                    Toggle("List attached disk images (for testing)", isOn: $model.settings.showDiskImages)
                    if let d = model.selectedDevice {
                        DeviceDetails(device: d)
                    }
                    if !model.excludedDevices.isEmpty {
                        DisclosureGroup {
                            ForEach(model.excludedDevices) { d in
                                Text("\(deviceLine(d)): \(exclusionText(d.exclusion))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } label: {
                            Text("Hidden devices (\(model.excludedDevices.count))").font(.callout)
                        }
                    }
                }
                .toggleStyle(.checkbox)
                .padding(.leading, 4)
                .disabled(model.isBusy)
            }
        }
    }

    var isDD: Bool { model.options?.mode == .dd }

    var schemeBinding: Binding<PartitionScheme?> {
        Binding(
            get: { isDD ? nil : (model.options?.scheme ?? .gpt) },
            set: { if let s = $0 { model.options?.scheme = s } })
    }

    var ddSchemeName: String {
        switch model.report?.layout?.scheme {
        case .gpt?: String(localized: "GPT (from the image)")
        case .mbr?: String(localized: "MBR (from the image)")
        case nil: String(localized: "From the image")
        }
    }

    var targetText: String {
        guard let report = model.report, let options = model.options else { return "—" }
        let t = WritePlanner.targets(report: report, mode: options.mode)
        if options.mode == .isoExtract { return String(localized: "UEFI (non CSM)") }
        if t.contains("bios") && t.contains("uefi") { return String(localized: "BIOS or UEFI") }
        if t.contains("uefi") { return "UEFI" }
        if t.contains("bios") { return String(localized: "BIOS (or UEFI-CSM)") }
        return String(localized: "Unknown")
    }

    var targetHelp: String {
        guard let report = model.report, let options = model.options else {
            return String(localized: "The target system depends on the selected image.")
        }
        let t = WritePlanner.targets(report: report, mode: options.mode)
        let list = t.isEmpty ? String(localized: "Unknown — the image may not boot") : t.map(targetName).joined(separator: ", ")
        return String(localized: "Expected to boot on: \(list).") + " "
            + (options.mode == .isoExtract
               ? String(localized: "ISO mode creates UEFI-only media (no BIOS/CSM boot): the target PC must boot in UEFI mode.")
               : String(localized: "DD mode keeps the boot methods designed by the image author."))
    }

    func deviceLine(_ d: DiskDevice) -> String {
        "\(d.facts.displayName) (\(d.facts.bsdName)) [\(model.formatBytes(d.facts.size))]"
    }
}

func imageOptionName(_ m: WriteMode, report: ImageReport) -> String {
    switch m {
    case .dd: return String(localized: "Write in DD image mode")
    case .isoExtract:
        return report.iso?.windows != nil
            ? String(localized: "Standard Windows installation")
            : String(localized: "Write in ISO image mode (extract to FAT32)")
    }
}

/// Only the warnings and errors from the analysis, compactly.
struct ImageNotes: View {
    let report: ImageReport

    var body: some View {
        let shown = report.notes.filter { $0.level != .info || $0.code == "wimWillBeSplit" || $0.code == "ddRecommendedLinux" }
        if !shown.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(shown, id: \.self) { NoteRow(note: $0) }
            }
        }
    }
}

struct DeviceDetails: View {
    @Environment(AppModel.self) private var model
    let device: DiskDevice

    var body: some View {
        let f = device.facts
        DisclosureGroup {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                row("Identifier", "/dev/\(f.bsdName)")
                row("Capacity", "\(model.formatBytes(f.size)) (\(f.size) bytes)")
                if let v = f.vendor { row("Manufacturer", v) }
                if let m = f.model { row("Model", m) }
                row("Connection", f.connection ?? "—")
                row("Block size", "\(f.blockSize) bytes")
                row("Removable media", f.removable ? String(localized: "Yes") : String(localized: "No"))
                if let c = f.contentType { row("Partition scheme", c) }
                ForEach(device.partitions) { p in
                    row("\(p.bsdName)", "\(p.volumeName ?? p.content ?? "—") \(p.fileSystem.map { "(\($0))" } ?? "") \(model.formatBytes(p.size))")
                }
            }
            .font(.caption)
            HStack {
                if f.ejectable {
                    Button("Eject") { model.eject(device) }
                }
                Button("Never show this device again") { model.excludeSelectedDevice() }
            }
            .font(.caption)
        } label: {
            Text("Device details").font(.callout)
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

// MARK: - Format options

struct FormatOptions: View {
    @Environment(AppModel.self) private var model
    @AppStorage("showAdvancedFormat") private var showAdvanced = false

    var body: some View {
        @Bindable var model = model
        let options = model.options
        let iso = options?.mode == .isoExtract
        VStack(alignment: .leading, spacing: 10) {
            Field(label: "Volume label") {
                TextField("Volume label", text: Binding(
                    get: { iso ? (options?.label ?? "") : (model.report?.label ?? "") },
                    set: { model.options?.label = $0 }))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .disabled(!iso || model.isBusy)
                    .help("FAT labels are limited to 11 characters; invalid characters are replaced. Linux boot files referencing the ISO label are updated to match.")
            }
            HStack(alignment: .top, spacing: 14) {
                Field(label: "File system") {
                    Picker("File system", selection: .constant(0)) {
                        Text(iso ? "FAT32" : (options == nil ? "—" : String(localized: "From the image"))).tag(0)
                    }
                    .labelsHidden()
                    .disabled(true)
                    .help("FAT32 is the file system every UEFI firmware must read. NTFS, exFAT and ext are not offered: macOS cannot create them reliably for bootable media.")
                }
                Field(label: "Cluster size") {
                    if iso, let f = model.fat32, let o = options {
                        Picker("Cluster size", selection: Binding(
                            get: { o.clusterSize ?? f.default },
                            set: { model.options?.clusterSize = $0 == f.default ? nil : $0 })) {
                            ForEach(f.valid, id: \.self) { c in
                                Text(c == f.default ? String(localized: "\(c) bytes (default)") : String(localized: "\(c) bytes")).tag(c)
                            }
                        }
                        .labelsHidden()
                        .disabled(model.isBusy)
                    } else {
                        Picker("Cluster size", selection: .constant(0)) { Text("—").tag(0) }
                            .labelsHidden()
                            .disabled(true)
                    }
                }
            }
            AdvancedToggle(show: "Show advanced format options", hide: "Hide advanced format options", expanded: $showAdvanced)
            if showAdvanced {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Verify by reading back after writing", isOn: Binding(
                        get: { model.options?.verify ?? model.settings.verifyAfterWrite },
                        set: { model.options?.verify = $0 }))
                        .help("Reads the written data back from the device and compares it. Doubles the time but detects faulty or counterfeit drives.")
                    HStack {
                        Toggle("Check device for bad blocks", isOn: $model.badBlocksBeforeWrite)
                            .help("Writes test patterns over the whole device before writing the image. Also detects counterfeit drives. Takes a long time.")
                        Spacer()
                        Picker("Passes", selection: $model.badBlocksPasses) {
                            Text("1 pass").tag(UInt32(1))
                            Text("2 passes").tag(UInt32(2))
                            Text("4 passes").tag(UInt32(4))
                        }
                        .labelsHidden()
                        .frame(width: 200)
                        .disabled(!model.badBlocksBeforeWrite)
                    }
                }
                .toggleStyle(.checkbox)
                .padding(.leading, 4)
                .disabled(model.isBusy || options == nil)
            }
        }
    }
}

// MARK: - Status

/// Rufus' big status bar: green "READY", progress with phase and percentage.
struct StatusBarBig: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let (fraction, text, color) = state
        ZStack {
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Rectangle().fill(Color.secondary.opacity(0.15))
                    Rectangle().fill(color).frame(width: g.size.width * fraction)
                }
            }
            Text(text)
                .font(.callout.weight(.medium))
                .foregroundStyle(fraction > 0.5 ? .white : .primary)
                .lineLimit(1)
                .padding(.horizontal, 6)
        }
        .frame(height: 26)
        .overlay(Rectangle().strokeBorder(Color.secondary.opacity(0.4)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Status"))
        .accessibilityValue(Text(text))
    }

    var state: (Double, String, Color) {
        let green = Color(red: 0.02, green: 0.69, blue: 0.13)
        switch model.operation {
        case .idle, .succeeded:
            return (1, String(localized: "READY"), green)
        case .failed:
            return (1, String(localized: "ERROR"), .red)
        case .cancelled:
            return (1, String(localized: "CANCELLED"), .orange)
        case .running(_, let p):
            let f = p?.fraction ?? 0
            var t = phaseName(p?.phase).uppercased()
            if let p, p.total > 0 { t += String(format: " %.1f%%", f * 100) }
            return (f, t, .accentColor)
        }
    }
}

struct BottomButtons: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Binding var advanced: AdvancedAction?
    @Binding var showAbout: Bool

    var body: some View {
        HStack(spacing: 14) {
            Menu {
                Button("Check device for bad blocks…") { advanced = .badBlocks }
                Button("Erase device (write zeros)…") { advanced = .zero }
                Divider()
                Button("Save device to image…") { advanced = .save }
            } label: {
                Image(systemName: "wrench.and.screwdriver")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(model.isBusy || model.selectedDevice == nil)
            .help("Tools")
            .accessibilityLabel(Text("Tools"))
            iconButton("info.circle", "About iRufus") { showAbout = true }
            SettingsLink {
                Image(systemName: "slider.horizontal.3").font(.title2)
            }
            .buttonStyle(.borderless)
            .help("Settings")
            .accessibilityLabel(Text("Settings"))
            iconButton("list.bullet.rectangle", "Log") { openWindow(id: "log") }
            Spacer()
            if model.isBusy {
                Button { model.cancelOperation() } label: { Text("CANCEL").frame(width: 110) }
                    .controlSize(.large)
                    .keyboardShortcut(.cancelAction)
            } else {
                Button { model.startPressed() } label: { Text("START").frame(width: 110) }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canStart)
                    .help(startHelp)
            }
            Button { NSApplication.shared.terminate(nil) } label: { Text("CLOSE").frame(width: 110) }
                .controlSize(.large)
                .disabled(model.isBusy)
        }
        .foregroundStyle(Color.accentColor)
    }

    func iconButton(_ symbol: String, _ help: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.title2) }
            .buttonStyle(.borderless)
            .help(help)
            .accessibilityLabel(Text(help))
    }

    var startHelp: String {
        if model.selectedDevice == nil { return String(localized: "Select a device first.") }
        if model.report == nil { return String(localized: "Select an image first.") }
        if let issue = model.planIssues.first { return issueText(issue, model: model) ?? "" }
        return String(localized: "Write the image to the selected device.")
    }
}

@MainActor
func issueText(_ issue: PlanIssue, model: AppModel) -> String? {
    switch issue {
    case .noDevice: String(localized: "Select a device first.")
    case .noImage: String(localized: "Select an image first.")
    case .deviceNotSelectable(let e): exclusionText(e)
    case .modeUnavailable: String(localized: "The selected mode is not available for this image.")
    case .imageLargerThanDevice(let needed, let available):
        String(localized: "The device is too small: \(model.formatBytes(needed)) needed, \(model.formatBytes(available)) available.")
    case .deviceTooSmallForFat32: String(localized: "The device is too small for a FAT32 partition.")
    case .schemeRequired: String(localized: "Choose a partition scheme.")
    case .answerFileConflict: String(localized: "The ISO already contains an answer file.")
    case .invalidAccountName: String(localized: "The local account name is not valid.")
    }
}

/// Bottom strip: last message on the left, elapsed/remaining time on the right.
struct FooterBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                Text(message)
                    .lineLimit(2)
                    .foregroundStyle(messageColor)
                    .textSelection(.enabled)
                Spacer(minLength: 8)
                Divider().frame(height: 16)
                Text(rightText)
                    .monospacedDigit()
                    .frame(minWidth: 90, alignment: .trailing)
            }
            .font(.callout)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.6))
    }

    var message: String {
        if case .running(let title, let p) = model.operation {
            var s = "\(title): \(phaseName(p?.phase))"
            if let p, p.total > 0 { s += " — \(model.formatBytes(p.done)) / \(model.formatBytes(p.total))" }
            return s
        }
        if model.analyzing { return String(localized: "Analysing image…") }
        return model.statusMessage
    }

    var messageColor: Color {
        switch model.operation {
        case .failed: .red
        case .cancelled: .orange
        default: .primary
        }
    }

    var rightText: String {
        if case .running(_, let p) = model.operation, let p {
            let rate = Format.rate(p.bytesPerSecond, binary: model.settings.binaryUnits)
            if let eta = p.eta { return "\(rate) · \(Format.duration(eta))" }
            return rate
        }
        return ""
    }
}

// MARK: - Shared helpers

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
            Text(noteText(note)).font(.caption)
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
