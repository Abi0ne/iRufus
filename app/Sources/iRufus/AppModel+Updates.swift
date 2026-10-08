import AppKit
import Foundation
import IrufusCore

/// What the update machinery is doing, shown in Settings and in the update alert.
struct UpdateStatus: Equatable {
    enum Phase: Equatable {
        case idle
        case checking
        case upToDate
        case available(ReleaseInfo)
        case downloading(ReleaseInfo)
        case ready(ReleaseInfo)
        case failed(String)
    }

    var phase: Phase = .idle
    var lastCheck: Date? = UserDefaults.standard.object(forKey: UpdateStatus.lastCheckKey) as? Date
    /// Show the update alert (results of a manual check, or an update to confirm/restart for).
    var showAlert = false

    static let lastCheckKey = "lastUpdateCheck"
    static let interval: TimeInterval = 24 * 60 * 60

    var isWorking: Bool {
        switch phase {
        case .checking, .downloading: true
        default: false
        }
    }
}

extension AppModel {
    private static var session: URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 30
        c.httpAdditionalHeaders = ["User-Agent": "iRufus/\(appVersion)"]
        return URLSession(configuration: c)
    }

    func checkForUpdatesAtLaunch() {
        guard settings.checkForUpdates else { return }
        if let last = update.lastCheck, Date().timeIntervalSince(last) < UpdateStatus.interval { return }
        Task { await checkForUpdates(userInitiated: false) }
    }

    func checkForUpdates(userInitiated: Bool) async {
        guard !update.isWorking else { return }
        if case .ready = update.phase {
            update.showAlert = userInitiated
            return
        }
        guard let current = AppVersion(Self.appVersion) else {
            log.add("Update check skipped: development build", level: .warning)
            update.phase = .failed(String(localized: "Updates are not available for development builds."))
            update.showAlert = userInitiated
            return
        }
        update.phase = .checking
        log.add("Checking for updates (\(UpdateFeed.repository))")
        do {
            var req = URLRequest(url: UpdateFeed.latestReleaseURL)
            req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, response) = try await Self.session.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            update.lastCheck = Date()
            UserDefaults.standard.set(update.lastCheck, forKey: UpdateStatus.lastCheckKey)
            if status == 404 {
                log.add("No release published yet")
                update.phase = .upToDate
                update.showAlert = userInitiated
                return
            }
            guard status == 200 else { throw UpdateError.network("HTTP \(status)") }
            let release = try UpdateFeed.parseLatestRelease(data)
            guard release.version > current else {
                log.add("iRufus is up to date (latest release \(release.version))")
                update.phase = .upToDate
                update.showAlert = userInitiated
                return
            }
            log.add("Update available: \(release.version)")
            if settings.installUpdatesAutomatically {
                await downloadUpdate(release, userInitiated: userInitiated)
            } else {
                update.phase = .available(release)
                update.showAlert = true
            }
        } catch {
            updateFailed(error, userInitiated: userInitiated)
        }
    }

    /// Download, verify the signature and unpack next to the installed app.
    /// The swap happens on quit or with installUpdateNow().
    func downloadUpdate(_ release: ReleaseInfo, userInitiated: Bool = true) async {
        update.phase = .downloading(release)
        update.showAlert = false
        do {
            let target = try UpdateInstaller.installationTarget()
            let (sigData, sigResponse) = try await Self.session.data(from: release.signatureURL)
            try Self.requireOK(sigResponse)
            let (tmp, zipResponse) = try await Self.session.download(from: release.archiveURL)
            defer { try? FileManager.default.removeItem(at: tmp) }
            try Self.requireOK(zipResponse)
            let archive = try Data(contentsOf: tmp)
            guard archive.count <= UpdateFeed.maxArchiveSize else { throw UpdateError.malformedRelease("archive too large") }
            guard UpdateFeed.verify(archive: archive, signature: sigData) else { throw UpdateError.badSignature }
            log.add("Update \(release.version) downloaded, signature valid")
            let bundleID = Bundle.main.bundleIdentifier ?? ""
            let app = try await Task.detached {
                try UpdateInstaller.stage(archive: tmp, version: release.version, target: target, bundleID: bundleID)
            }.value
            stagedUpdate = (app, target)
            update.phase = .ready(release)
            update.showAlert = true
            log.add("Update \(release.version) ready; it will be installed when iRufus quits")
        } catch {
            updateFailed(error, userInitiated: userInitiated)
        }
    }

    /// Swap the bundles after quitting and relaunch the new version.
    func installUpdateNow() {
        guard !isBusy, let staged = stagedUpdate else { return }
        do {
            try UpdateInstaller.scheduleReplacement(staged: staged.app, target: staged.target, relaunch: true)
            stagedUpdate = nil
            log.add("Installing update and relaunching")
            NSApp.terminate(nil)
        } catch {
            updateFailed(error, userInitiated: true)
        }
    }

    /// Called when iRufus quits: a downloaded update replaces the app without relaunching it.
    func installStagedUpdateOnQuit() {
        guard let staged = stagedUpdate else { return }
        stagedUpdate = nil
        try? UpdateInstaller.scheduleReplacement(staged: staged.app, target: staged.target, relaunch: false)
    }

    private func updateFailed(_ error: Error, userInitiated: Bool) {
        let message = Self.describeUpdateError(error)
        log.add("Update failed: \(error)", level: userInitiated ? .error : .warning)
        update.phase = .failed(message)
        update.showAlert = userInitiated
    }

    private static func requireOK(_ response: URLResponse) throws {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw UpdateError.network("HTTP \(status)") }
    }

    static func describeUpdateError(_ error: Error) -> String {
        switch error {
        case UpdateError.badSignature:
            return String(localized: "The downloaded update is not signed with the iRufus key and was discarded.")
        case UpdateError.translocated:
            return String(localized: "macOS is running iRufus from a temporary location. Move iRufus to the Applications folder, open it from there and try again.")
        case UpdateError.notWritable:
            return String(localized: "iRufus cannot replace itself in its current folder. Move it to a folder you can write to, such as Applications.")
        case UpdateError.missingAsset, UpdateError.malformedRelease, UpdateError.unexpectedBundle:
            return String(localized: "The latest release on GitHub does not contain a valid iRufus update package.")
        case UpdateError.network, is URLError:
            return String(localized: "Could not reach GitHub. Check your internet connection.")
        default:
            return String(localized: "The update could not be installed.")
        }
    }
}
