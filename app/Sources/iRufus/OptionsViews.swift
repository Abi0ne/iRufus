import IrufusCore
import SwiftUI

struct OptionsSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        if let report = model.report, let options = model.options {
            Section {
                if report.modes.count > 1 {
                    Picker("Write mode", selection: Binding(
                        get: { options.mode },
                        set: { model.options?.mode = $0 })) {
                        ForEach(report.modes, id: \.self) { m in
                            Text(modeName(m)).tag(m)
                        }
                    }
                    .help("DD copies the image bit for bit. ISO mode creates a FAT32 partition and copies the files, so the drive stays usable for data.")
                } else if let only = report.modes.first {
                    LabeledContent("Write mode", value: modeName(only))
                }
                Text(modeExplanation(options.mode))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if options.mode == .isoExtract {
                    Picker("Partition scheme", selection: Binding(
                        get: { options.scheme },
                        set: { model.options?.scheme = $0 })) {
                        Text("GPT").tag(PartitionScheme.gpt)
                        Text("MBR").tag(PartitionScheme.mbr)
                    }
                    .pickerStyle(.segmented)
                    Text(options.scheme == .gpt
                         ? "GPT: recommended for UEFI PCs made after 2012 and for disks over 2 TB."
                         : "MBR: for older UEFI firmware that does not boot GPT USB drives. Still UEFI only.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    LabeledContent("File system", value: "FAT32")
                        .help("FAT32 is the file system every UEFI firmware must read. NTFS, exFAT and ext are not offered: macOS cannot create them reliably for bootable media.")
                    if let f = model.fat32 {
                        Picker("Cluster size", selection: Binding(
                            get: { options.clusterSize ?? f.default },
                            set: { model.options?.clusterSize = $0 == f.default ? nil : $0 })) {
                            ForEach(f.valid, id: \.self) { c in
                                Text(c == f.default ? String(localized: "\(model.formatBytes(UInt64(c))) (default)") : model.formatBytes(UInt64(c))).tag(c)
                            }
                        }
                    }
                    TextField("Volume label", text: Binding(
                        get: { options.label },
                        set: { model.options?.label = $0 }))
                        .help("FAT labels are limited to 11 characters; invalid characters are replaced. Linux boot files referencing the ISO label are updated to match.")
                }
                LabeledContent("Target system") {
                    let targets = WritePlanner.targets(report: report, mode: options.mode)
                    Text(targets.isEmpty ? String(localized: "Unknown — the image may not boot") : targets.map(targetName).joined(separator: ", "))
                }
                Toggle("Verify by reading back after writing", isOn: Binding(
                    get: { options.verify },
                    set: { model.options?.verify = $0 }))
                    .help("Reads the written data back from the device and compares it. Doubles the time but detects faulty or counterfeit drives.")
                ForEach(issueTexts, id: \.self) { t in
                    Label(t, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout)
                }
            } header: {
                Text("Format options")
            }
        }
    }

    func modeExplanation(_ m: WriteMode) -> String {
        switch m {
        case .dd: String(localized: "The whole device is replaced by the image, including its partition table. Remaining space is not usable until the drive is reformatted.")
        case .isoExtract: String(localized: "Creates one FAT32 partition and copies the ISO content. Bootable on UEFI firmware only.")
        }
    }

    var issueTexts: [String] {
        model.planIssues.compactMap { issue in
            switch issue {
            case .noDevice, .noImage, .deviceNotSelectable: nil
            case .modeUnavailable: String(localized: "The selected mode is not available for this image.")
            case .imageLargerThanDevice(let needed, let available):
                String(localized: "The device is too small: \(model.formatBytes(needed)) needed, \(model.formatBytes(available)) available.")
            case .deviceTooSmallForFat32: String(localized: "The device is too small for a FAT32 partition.")
            case .schemeRequired: String(localized: "Choose a partition scheme.")
            case .answerFileConflict: String(localized: "The ISO already contains an answer file.")
            case .invalidAccountName: String(localized: "The local account name is not valid.")
            }
        }
    }
}

struct WindowsSection: View {
    @Environment(AppModel.self) private var model
    @State private var preview: AnswerFilePreview?

    var body: some View {
        if let report = model.report, let options = model.options, let w = report.iso?.windows {
            Section {
                Toggle("Customise Windows installation", isOn: Binding(
                    get: { options.wueEnabled },
                    set: { model.options?.wueEnabled = $0 }))
                if options.wueEnabled {
                    Group {
                        if w.isWindows11 {
                            toggle("Remove the requirement for TPM 2.0, Secure Boot and 4 GB RAM", \.bypassRequirements,
                                   help: "Adds LabConfig registry values during Windows Setup. Works when booting from this USB drive (clean install), not for upgrades started from Windows.")
                        }
                        toggle("Remove the requirement for an online Microsoft account", \.noOnlineAccount,
                               help: "Sets BypassNRO. Incompatible with PCs locked in Windows S Mode.")
                        toggle("Create a local account", \.createLocalAccount,
                               help: "The account is created with an empty password; Windows asks to set one at first sign-in.")
                        if options.wue.createLocalAccount {
                            TextField("Account name", text: Binding(
                                get: { options.wue.accountName },
                                set: { model.options?.wue.accountName = $0 }))
                            if let err = model.accountNameError {
                                Text(err).font(.caption).foregroundStyle(.red)
                            }
                        }
                        toggle("Disable data collection (skip privacy questions)", \.disableDataCollection, help: nil)
                        toggle("Use this Mac's regional settings", \.copyRegionalSettings,
                               help: "Language, locale and keyboard; the time zone is not copied. The ISO must include the language.")
                        toggle("Disable automatic BitLocker device encryption", \.disableBitlocker, help: nil)
                    }
                    .padding(.leading, 12)
                    Button("Show answer file…") { preview = model.answerFilePreview() }
                        .disabled(model.answerFilePreview() == nil)
                }
                Text("These options are written as a Windows Setup answer file on the USB drive (Autounattend.xml or sources/$OEM$). They act only during installation from this drive and only on Windows images that honour them; iRufus cannot verify their effect on the target PC.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Windows customisation")
            }
            .sheet(item: $preview) { p in
                AnswerFileView(preview: p)
            }
        }
    }

    func toggle(_ title: LocalizedStringKey, _ key: WritableKeyPath<WueSelection, Bool>, help: LocalizedStringKey?) -> some View {
        Toggle(title, isOn: Binding(
            get: { model.options?.wue[keyPath: key] ?? false },
            set: { model.options?.wue[keyPath: key] = $0 }))
            .help(help ?? title)
    }
}

extension AnswerFilePreview: Identifiable {
    public var id: String { path + xml }
}

struct AnswerFileView: View {
    @Environment(\.dismiss) private var dismiss
    let preview: AnswerFilePreview

    var body: some View {
        VStack(alignment: .leading) {
            Text("Path on the USB drive: \(preview.path)").font(.headline)
            ScrollView {
                Text(preview.xml)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 640, height: 480)
    }
}
