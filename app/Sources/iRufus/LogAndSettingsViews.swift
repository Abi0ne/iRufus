import IrufusCore
import SwiftUI
import UniformTypeIdentifiers

struct LogView: View {
    @Environment(AppModel.self) private var model
    @State private var exporting = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                List(model.logEntries) { e in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(e.date, format: .dateTime.hour().minute().second())
                            .foregroundStyle(.secondary)
                        Text(e.message)
                            .foregroundStyle(e.level == .error ? .red : e.level == .warning ? .orange : .primary)
                            .textSelection(.enabled)
                    }
                    .font(.system(.caption, design: .monospaced))
                    .id(e.id)
                }
                .onChange(of: model.logEntries.count) {
                    if let last = model.logEntries.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            Divider()
            HStack {
                Text("Personal data (home folder, user name, Windows account name) is removed from the log.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Clear") { model.clearLog() }
                Button("Export…") { exporting = true }
            }
            .padding(8)
        }
        .fileExporter(isPresented: $exporting, document: LogDocument(text: model.exportLog()), contentType: .plainText,
                      defaultFilename: "iRufus-log.txt") { _ in }
    }
}

struct LogDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }
    var text: String

    init(text: String) {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        TabView {
            Form {
                Section("Devices") {
                    Toggle("List USB hard drives and SSDs", isOn: $model.settings.showUSBHardDrives)
                    Text("Off by default, like in Rufus: external hard drives often hold backups.")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("List attached disk images (for testing)", isOn: $model.settings.showDiskImages)
                    Text("Shows virtual disks attached with Disk Utility or hdiutil, useful to try iRufus without a USB drive.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Internal disks, the startup disk and the disk holding the selected image are never listed.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Excluded devices") {
                    if model.settings.excludedDevices.isEmpty {
                        Text("None").foregroundStyle(.secondary)
                    }
                    ForEach(model.settings.excludedDevices.sorted(by: { $0.value < $1.value }), id: \.key) { key, name in
                        HStack {
                            Text(name)
                            Spacer()
                            Button("Remove") { model.settings.excludedDevices.removeValue(forKey: key) }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Devices", systemImage: "externaldrive") }

            Form {
                Toggle("Verify by reading back after writing (default)", isOn: $model.settings.verifyAfterWrite)
                Toggle("Use binary units (GiB instead of GB)", isOn: $model.settings.binaryUnits)
                Section("Default checksums") {
                    ForEach(HashAlgorithm.allCases) { a in
                        Toggle(a.displayName, isOn: Binding(
                            get: { model.settings.defaultHashes.contains(a) },
                            set: { on in
                                if on { model.settings.defaultHashes.insert(a) } else if model.settings.defaultHashes.count > 1 {
                                    model.settings.defaultHashes.remove(a)
                                }
                            }))
                    }
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("General", systemImage: "gearshape") }

            AboutView()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 520, height: 460)
    }
}

struct AboutView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("iRufus \(AppModel.appVersion)").font(.title2.bold())
                Text("Engine \(Engine.version)")
                Text("A macOS port of the functions of Rufus by Pete Batard / Akeo Consulting (https://rufus.ie), licensed under the GNU General Public License v3 or later.")
                Text("iRufus is free software: you can redistribute it and/or modify it under the terms of the GNU GPL v3 or later. It comes with ABSOLUTELY NO WARRANTY. The full source code and the third-party licences are distributed with the application (Contents/Resources/LICENSES).")
                Text("Third-party components: fatfs (MIT, patched), RustCrypto hashes (MIT/Apache-2.0), flate2/miniz_oxide, xz2/liblzma, zstd, bzip2, zip, serde (MIT/Apache-2.0/BSD/0BSD). No Microsoft or boot-loader binaries are included.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding()
            .textSelection(.enabled)
        }
    }
}
