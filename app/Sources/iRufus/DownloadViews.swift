import AppKit
import IrufusCore
import SwiftUI

/// "Download an operating system": official images, verified before use.
struct DownloadSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        @Bindable var model = model
        let phase = model.download.phase
        let locked = model.download.isWorking || { if case .paused = phase { return true } else { return false } }()
        VStack(alignment: .leading, spacing: 12) {
            Text("Download an Operating System").font(.title2.bold())
            Text("Images come from the publisher's own server and are used only after their SHA-256 checksum has been verified.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Picker("Operating system", selection: $model.download.product) {
                ForEach(DownloadProduct.allCases) { p in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(productName(p))
                        Text(productSummary(p)).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 2)
                    .tag(p)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            .disabled(locked)
            .onChange(of: model.download.product) { model.resolveDownload() }

            if model.download.product.family == .windows, !model.download.windowsLanguages.isEmpty {
                Picker("Language", selection: Binding(
                    get: { model.download.windowsLanguage ?? "" },
                    set: { model.download.windowsLanguage = $0; model.resolveDownload() })) {
                    ForEach(model.download.windowsLanguages) { l in
                        Text(l.localizedName).tag(l.name)
                    }
                }
                .disabled(locked)
                .frame(maxWidth: 320)
            }

            Divider()
            details(phase)

            HStack(spacing: 6) {
                Text("Save to:").foregroundStyle(.secondary)
                Text(model.download.folder.path)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(model.download.folder.path)
                Spacer()
                Button("Change…", action: chooseFolder).disabled(locked)
            }
            .font(.callout)

            HStack {
                buttons(phase)
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .help("A download in progress continues in the background.")
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    @ViewBuilder
    private func details(_ phase: DownloadStatus.Phase) -> some View {
        switch phase {
        case .idle:
            EmptyView()
        case .resolving:
            ProgressView("Looking up the latest version…").controlSize(.small)
        case .ready(let d, let size, let existing):
            info(d, size: size)
            if existing {
                Label("\(d.fileName) is already in this folder: it will be verified instead of downloaded again.",
                      systemImage: "doc.badge.clock")
                    .font(.callout)
            }
        case .downloading(let d, let received, let total, let rate):
            info(d, size: total)
            ProgressView(value: total.map { Double(received) / Double(max($0, 1)) })
                .accessibilityLabel(Text("Download progress"))
            Text(progressLine(received: received, total: total, rate: rate))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        case .paused(let d, let received, let total):
            info(d, size: total)
            Label("Paused at \(model.formatBytes(UInt64(received)))", systemImage: "pause.circle")
                .font(.callout)
        case .verifying(let d, let progress):
            info(d, size: nil)
            ProgressView("Verifying SHA-256…", value: progress)
        case .finished(let d, let url):
            info(d, size: nil)
            Label("Verified and saved to \(url.path)", systemImage: "checkmark.seal.fill")
                .foregroundStyle(.green)
                .font(.callout)
                .textSelection(.enabled)
        case .failed(let message):
            Label(message, systemImage: "xmark.octagon")
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func info(_ d: ResolvedDownload, size: Int64?) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
            GridRow {
                Text("Version").foregroundStyle(.secondary)
                Text(d.version)
            }
            GridRow {
                Text("File").foregroundStyle(.secondary)
                Text(size.map { "\(d.fileName) (\(model.formatBytes(UInt64($0))))" } ?? d.fileName)
                    .textSelection(.enabled)
            }
            GridRow {
                Text("Source").foregroundStyle(.secondary)
                Text(d.url.host ?? "").textSelection(.enabled)
            }
            GridRow(alignment: .top) {
                Text("Verification").foregroundStyle(.secondary)
                verification(d.verification)
            }
        }
        .font(.callout)
    }

    @ViewBuilder
    private func verification(_ v: DownloadVerification) -> some View {
        switch v {
        case .signedChecksums(let name, let fp):
            VStack(alignment: .leading, spacing: 2) {
                Text("Checksum list signed by \(name)")
                Text(OpenPGPKey(name: name, fingerprint: fp, packet: "").formattedFingerprint)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        case .signedImage(let name, let fp):
            VStack(alignment: .leading, spacing: 2) {
                Text("Image signed by \(name)")
                Text(OpenPGPKey(name: name, fingerprint: fp, packet: "").formattedFingerprint)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        case .pinnedChecksum:
            Text("Checksum of this release built into iRufus")
        case .publishedChecksum(let page):
            VStack(alignment: .leading, spacing: 2) {
                Text("SHA-256 published by Microsoft on its download page")
                Text(page.absoluteString)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    @ViewBuilder
    private func buttons(_ phase: DownloadStatus.Phase) -> some View {
        switch phase {
        case .ready(_, _, let existing):
            Button(existing ? "Verify" : "Download") { model.startDownload() }
                .keyboardShortcut(.defaultAction)
        case .downloading:
            Button("Pause") { model.cancelDownload() }
        case .resolving, .verifying:
            Button("Cancel") { model.cancelDownload() }
        case .paused:
            Button("Resume") { model.startDownload() }
                .keyboardShortcut(.defaultAction)
            Button("Discard") { model.discardPartialDownload() }
        case .finished:
            Button("Use This Image") { model.useDownloadedImage() }
                .keyboardShortcut(.defaultAction)
                .disabled(model.isBusy)
            Button("Show in Finder") {
                if case .finished(_, let url) = phase { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
        case .failed, .idle:
            Button("Try Again") { model.resolveDownload() }
            if model.download.product.family == .windows {
                Button("Open Microsoft's Page") { openURL(WindowsDownload.pageURL(model.download.product)) }
            }
        }
    }

    private func progressLine(received: Int64, total: Int64?, rate: Double) -> String {
        var s = model.formatBytes(UInt64(received))
        if let total { s += " / " + model.formatBytes(UInt64(total)) }
        if rate > 0 {
            s += " — " + Format.rate(rate, binary: model.settings.binaryUnits)
            if let total, total > received {
                s += " — " + String(localized: "\(Format.duration(Double(total - received) / rate)) left")
            }
        }
        return s
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = model.download.folder
        panel.prompt = String(localized: "Choose")
        if panel.runModal() == .OK, let url = panel.url {
            model.chooseDownloadFolder(url)
        }
    }

    private func productName(_ p: DownloadProduct) -> String {
        switch p {
        case .windows11: String(localized: "Windows 11 (64-bit PCs)")
        case .windows11ARM: String(localized: "Windows 11 for Arm")
        case .ubuntuDesktop: String(localized: "Ubuntu Desktop (latest LTS)")
        case .systemRescue: String(localized: "SystemRescue (latest)")
        case .freeDOSLite: String(localized: "FreeDOS 1.4 — USB Lite")
        case .freeDOSFull: String(localized: "FreeDOS 1.4 — USB Full")
        }
    }

    private func productSummary(_ p: DownloadProduct) -> String {
        switch p {
        case .windows11:
            String(localized: "Official multi-edition ISO (Home, Pro, Education…) from Microsoft, latest version. Intel/AMD PCs, about 9 GB.")
        case .windows11ARM:
            String(localized: "For PCs with Arm processors (Snapdragon and others). About 8.5 GB.")
        case .ubuntuDesktop:
            String(localized: "Live system: try Ubuntu without installing it, rescue files, or install it. 64-bit PCs, about 6 GB.")
        case .systemRescue:
            String(localized: "Live rescue system: repair partitions and file systems, recover data, reset passwords, back up disks. 64-bit PCs, about 1.4 GB.")
        case .freeDOSLite:
            String(localized: "DOS for BIOS/firmware updates and old programs; needs a PC with BIOS or CSM. About 17 MB.")
        case .freeDOSFull:
            String(localized: "As Lite, with all FreeDOS packages (editors, compilers, games, networking). About 670 MB.")
        }
    }
}
