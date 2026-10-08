import AppKit
import IrufusCore
import SwiftUI
import UniformTypeIdentifiers

enum AdvancedAction: String, Identifiable {
    case badBlocks, zero, save
    var id: String { rawValue }
}

func phaseName(_ p: EnginePhase?) -> String {
    switch p {
    case nil, .preparing?: String(localized: "preparing (authorisation may be requested)")
    case .hashing?: String(localized: "computing checksum")
    case .partitioning?: String(localized: "partitioning")
    case .formatting?: String(localized: "formatting FAT32")
    case .writing?: String(localized: "writing")
    case .copyingFiles?: String(localized: "copying files")
    case .splittingWim?: String(localized: "splitting install.wim")
    case .syncing?: String(localized: "flushing device cache")
    case .verifying?: String(localized: "verifying")
    case .badBlocks?: String(localized: "testing blocks")
    case .reading?: String(localized: "reading")
    case .zeroing?: String(localized: "writing zeros")
    case .finalizing?: String(localized: "finalising")
    }
}

/// Irreversible-operation confirmation: shows model, capacity and identifier;
/// requires typing the identifier for large or ambiguously identified disks.
struct ConfirmSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let operation: PendingOperation
    @State private var acknowledged = false
    @State private var typed = ""

    var body: some View {
        let f = operation.facts
        VStack(alignment: .leading, spacing: 14) {
            Label {
                Text(operation.kind.isDestructive ? "All data on this device will be destroyed" : "Read the whole device")
                    .font(.title2.bold())
            } icon: {
                Image(systemName: operation.kind.isDestructive ? "exclamationmark.triangle.fill" : "externaldrive")
                    .foregroundStyle(operation.kind.isDestructive ? .red : .accentColor)
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                GridRow { Text("Device").foregroundStyle(.secondary); Text(f.displayName).bold() }
                GridRow { Text("Capacity").foregroundStyle(.secondary); Text("\(model.formatBytes(f.size)) (\(f.size) bytes)") }
                GridRow { Text("Identifier").foregroundStyle(.secondary); Text("/dev/\(f.bsdName)").font(.body.monospaced()) }
                GridRow { Text("Connection").foregroundStyle(.secondary); Text(f.connection ?? "—") }
                GridRow { Text("Operation").foregroundStyle(.secondary); Text(AppModel.title(for: operation.kind)) }
            }
            if operation.kind.isDestructive {
                Text("This cannot be undone. Partitions and files currently on the device, including those you cannot see in Finder, will be lost.")
                Toggle("I understand that all data on this device will be lost", isOn: $acknowledged)
                    .toggleStyle(.checkbox)
                if case .typeIdentifier(let reasons) = operation.level {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(reasons, id: \.self) { r in
                            Label(reasonText(r), systemImage: "exclamationmark.circle").foregroundStyle(.orange)
                        }
                        Text("For additional safety, type the device identifier (\(f.bsdName)) to continue:")
                        TextField(f.bsdName, text: $typed)
                            .font(.body.monospaced())
                            .accessibilityLabel(Text("Device identifier"))
                    }
                }
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    model.pending = nil
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button(operation.kind.isDestructive ? "Erase and continue" : "Continue", role: operation.kind.isDestructive ? .destructive : nil) {
                    model.confirm(operation)
                    dismiss()
                }
                .disabled(!canConfirm)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    var canConfirm: Bool {
        guard operation.kind.isDestructive else { return true }
        guard acknowledged else { return false }
        if case .typeIdentifier = operation.level {
            return typed.trimmingCharacters(in: .whitespaces) == operation.facts.bsdName
        }
        return true
    }

    func reasonText(_ r: ConfirmationLevel.Reason) -> String {
        switch r {
        case .largeDisk: String(localized: "This is a large disk (over 128 GB): make sure it is not a backup drive.")
        case .noVendorOrModel: String(localized: "The device does not report a manufacturer or model.")
        case .notRemovableMedia: String(localized: "The device is not removable media (external hard drive or SSD).")
        case .virtualDisk: String(localized: "This is an attached disk image, not a physical device.")
        }
    }
}

/// Parameters for the Tools menu operations, then the standard confirmation.
struct AdvancedSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let action: AdvancedAction
    @State private var passes: UInt32 = 1
    @State private var vhd = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch action {
            case .badBlocks:
                Text("Check for bad blocks").font(.title2.bold())
                Text("Writes test patterns over the whole device and reads them back. It also detects counterfeit drives that report more capacity than they have. THIS ERASES THE DEVICE.")
                Picker("Passes", selection: $passes) {
                    Text("1 pass (0xAA)").tag(UInt32(1))
                    Text("2 passes (0xAA, 0x55)").tag(UInt32(2))
                    Text("4 passes (0xAA, 0x55, 0xFF, 0x00)").tag(UInt32(4))
                }
                Text("Each pass writes and reads the entire device: on a slow USB 2.0 drive this can take hours.")
                    .font(.caption).foregroundStyle(.secondary)
            case .zero:
                Text("Erase device").font(.title2.bold())
                Text("Overwrites the entire device with zeros and verifies it. Use it to remove every partition and file system, for example after DD-writing a Linux image.")
            case .save:
                Text("Save device to image").font(.title2.bold())
                Text("Reads the entire device into an image file. Nothing is written to the device. Formats: raw (.img) or fixed VHD (.vhd). VHDX and FFU are not supported on macOS.")
                Toggle("Save as fixed VHD", isOn: $vhd)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Continue…") { proceed() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    func proceed() {
        switch action {
        case .badBlocks:
            dismiss()
            model.requestAdvanced(.badBlocks(passes: passes))
        case .zero:
            dismiss()
            model.requestAdvanced(.zero)
        case .save:
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "\(model.selectedDevice?.facts.bsdName ?? "disk").\(vhd ? "vhd" : "img")"
            panel.allowedContentTypes = [UTType(filenameExtension: vhd ? "vhd" : "img") ?? .data]
            panel.canCreateDirectories = true
            let format: Engine.SaveFormat = vhd ? .vhd : .raw
            dismiss()
            if panel.runModal() == .OK, let url = panel.url {
                model.requestAdvanced(.save(url, format))
            }
        }
    }
}
