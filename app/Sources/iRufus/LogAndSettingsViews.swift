import AppKit
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

            UpdateSettingsView()
                .tabItem { Label("Updates", systemImage: "arrow.down.circle") }

            AboutView()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 520, height: 460)
    }
}

struct UpdateSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Toggle("Check for updates automatically", isOn: $model.settings.checkForUpdates)
                Toggle("Download and install updates automatically", isOn: $model.settings.installUpdatesAutomatically)
                Text("iRufus checks GitHub (\(UpdateFeed.repository)) at most once a day. Updates are installed only if they are signed with the iRufus release key, and never while an operation is running: a downloaded update replaces the app when you quit iRufus.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    statusText
                    Spacer()
                    if model.update.isWorking {
                        ProgressView().controlSize(.small)
                    }
                    if case .ready = model.update.phase {
                        Button("Restart and Install") { model.installUpdateNow() }
                            .disabled(model.isBusy)
                    } else if case .available(let release) = model.update.phase {
                        Button("Download and Install") { Task { await model.downloadUpdate(release) } }
                    } else {
                        Button("Check Now") { Task { await model.checkForUpdates(userInitiated: false) } }
                            .disabled(model.update.isWorking)
                    }
                }
                if let last = model.update.lastCheck {
                    Text("Last check: \(last.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder private var statusText: some View {
        switch model.update.phase {
        case .idle: Text("Version \(AppModel.appVersion)")
        case .checking: Text("Checking for updates…")
        case .upToDate: Text("iRufus \(AppModel.appVersion) is up to date.")
        case .available(let r): Text("iRufus \(r.version.description) is available.")
        case .downloading(let r): Text("Downloading iRufus \(r.version.description)…")
        case .ready(let r): Text("iRufus \(r.version.description) is ready to install.")
        case .failed(let message): Text(message).foregroundStyle(.red)
        }
    }
}

struct UpdateAlert: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        @Bindable var model = model
        content.alert(title, isPresented: $model.update.showAlert) {
            switch model.update.phase {
            case .available(let release):
                Button("Download and Install") { Task { await model.downloadUpdate(release) } }
                Button("Release Notes") { NSWorkspace.shared.open(release.pageURL) }
                Button("Later", role: .cancel) {}
            case .ready:
                if !model.isBusy {
                    Button("Restart Now") { model.installUpdateNow() }
                }
                Button("Later", role: .cancel) {}
            default:
                Button("OK", role: .cancel) {}
            }
        } message: {
            Text(message)
        }
    }

    private var title: String {
        switch model.update.phase {
        case .available(let r): String(localized: "iRufus \(r.version.description) is available")
        case .ready(let r): String(localized: "iRufus \(r.version.description) is ready to install")
        case .upToDate: String(localized: "iRufus is up to date")
        case .failed: String(localized: "Update failed")
        default: ""
        }
    }

    private var message: String {
        switch model.update.phase {
        case .available(let r):
            let notes = r.notes.count > 600 ? String(r.notes.prefix(600)) + "…" : r.notes
            return notes.isEmpty ? String(localized: "You have version \(AppModel.appVersion).") : notes
        case .ready:
            return model.isBusy
                ? String(localized: "It will be installed when you quit iRufus, after the current operation.")
                : String(localized: "Restart now, or it will be installed when you quit iRufus.")
        case .upToDate:
            return String(localized: "You have the latest version (\(AppModel.appVersion)).")
        case .failed(let message):
            return message
        default:
            return ""
        }
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
