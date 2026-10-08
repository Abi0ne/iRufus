import IrufusCore
import SwiftUI

/// Opened by the ✓ button next to the boot selection, like Rufus' checksum dialog.
struct ChecksumSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 12) {
            Text("Checksums").font(.title2.bold())
            Text(model.imageURL?.lastPathComponent ?? "").foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            HStack {
                ForEach(HashAlgorithm.allCases) { a in
                    Toggle(a.displayName, isOn: Binding(
                        get: { model.hash.algorithms.contains(a) },
                        set: { on in if on { model.hash.algorithms.insert(a) } else { model.hash.algorithms.remove(a) } }))
                }
                Spacer()
                if model.hash.running {
                    Button("Stop") { model.cancelHashes() }
                } else {
                    Button("Compute") { model.computeHashes() }
                        .disabled(model.hash.algorithms.isEmpty)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .toggleStyle(.checkbox)
            if model.hash.running {
                ProgressView(value: model.hash.progress ?? 0).accessibilityLabel(Text("Checksum progress"))
            }
            if let r = model.hash.result {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                    ForEach(HashAlgorithm.allCases) { a in
                        if let v = r.value(for: a) {
                            GridRow {
                                Text(a.displayName).foregroundStyle(.secondary)
                                Text(v).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            }
                        }
                    }
                }
            }
            TextField("Expected checksum (paste from the official site)", text: $model.hash.expected)
                .font(.system(.body, design: .monospaced))
                .textFieldStyle(.roundedBorder)
            comparison
            Text("A matching checksum proves the file is intact (integrity). It proves authenticity only if the expected value comes from the publisher's official, secure page or a verified signature.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 600)
    }

    @ViewBuilder
    var comparison: some View {
        switch model.checksumComparison {
        case .empty: EmptyView()
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

/// Shown after START for Windows images, like Rufus' "Windows User Experience" dialog.
struct WindowsDialog: View {
    @Environment(AppModel.self) private var model
    @State private var preview: AnswerFilePreview?

    var body: some View {
        let w = model.report?.iso?.windows
        VStack(alignment: .leading, spacing: 10) {
            Text("Windows User Experience").font(.title2.bold())
            Text("Customise Windows installation?")
            Group {
                if w?.isWindows11 == true {
                    toggle("Remove the requirement for TPM 2.0, Secure Boot and 4 GB RAM", \.bypassRequirements,
                           help: "Adds LabConfig registry values during Windows Setup. Works when booting from this USB drive (clean install), not for upgrades started from Windows.")
                }
                toggle("Remove the requirement for an online Microsoft account", \.noOnlineAccount,
                       help: "Sets BypassNRO. Incompatible with PCs locked in Windows S Mode.")
                HStack {
                    toggle("Create a local account with username:", \.createLocalAccount,
                           help: "The account is created with an empty password; Windows asks to set one at first sign-in.")
                    TextField("Account name", text: Binding(
                        get: { model.options?.wue.accountName ?? "" },
                        set: { model.options?.wue.accountName = $0 }))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .disabled(model.options?.wue.createLocalAccount != true)
                }
                if model.options?.wue.createLocalAccount == true, let err = model.accountNameError {
                    Text(err).font(.caption).foregroundStyle(.red)
                }
                toggle("Disable data collection (skip privacy questions)", \.disableDataCollection, help: nil)
                toggle("Use this Mac's regional settings", \.copyRegionalSettings,
                       help: "Language, locale and keyboard; the time zone is not copied. The ISO must include the language.")
                toggle("Disable automatic BitLocker device encryption", \.disableBitlocker, help: nil)
            }
            .toggleStyle(.checkbox)
            Text("These options are written as a Windows Setup answer file on the USB drive (Autounattend.xml or sources/$OEM$). They act only during installation from this drive and only on Windows images that honour them; iRufus cannot verify their effect on the target PC.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Show answer file…") { preview = model.answerFilePreview() }
                    .disabled(model.answerFilePreview() == nil)
                Spacer()
                Button("Cancel") { model.windowsDialogFinished(proceed: false) }
                    .keyboardShortcut(.cancelAction)
                Button("OK") {
                    model.options?.wueEnabled = true
                    model.windowsDialogFinished(proceed: true)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.options?.wue.createLocalAccount == true && model.accountNameError != nil)
            }
        }
        .padding(20)
        .frame(width: 560)
        .sheet(item: $preview) { AnswerFileView(preview: $0) }
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

struct AboutSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .trailing) {
            AboutView()
            Button("Close") { dismiss() }
                .keyboardShortcut(.defaultAction)
                .padding([.trailing, .bottom])
        }
        .frame(width: 520, height: 360)
    }
}
