import Foundation
import IrufusCore

/// State of the "Download an operating system" sheet.
struct DownloadStatus: Equatable {
    enum Phase: Equatable {
        case idle
        case resolving
        /// `size` comes from the server and may be unknown; `existing` is a file of the same
        /// name already in the folder, which will be verified instead of downloaded again.
        case ready(ResolvedDownload, size: Int64?, existing: Bool)
        case downloading(ResolvedDownload, received: Int64, total: Int64?, bytesPerSecond: Double)
        /// Interrupted (by the user or the network); resumable when the server allows it.
        case paused(ResolvedDownload, received: Int64, total: Int64?)
        case verifying(ResolvedDownload, progress: Double)
        case finished(ResolvedDownload, URL)
        case failed(String)
    }

    var product: DownloadProduct = .windows11
    /// Windows: Microsoft's English name of the language to download; nil until known.
    var windowsLanguage: String?
    /// Languages Microsoft offered at the last lookup, for the picker.
    var windowsLanguages: [WindowsLanguage] = []
    var phase: Phase = .idle
    var folder: URL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        ?? FileManager.default.homeDirectoryForCurrentUser
    var showSheet = false

    var isWorking: Bool {
        switch phase {
        case .resolving, .downloading, .verifying: true
        default: false
        }
    }

    var resolved: ResolvedDownload? {
        switch phase {
        case .ready(let d, _, _), .downloading(let d, _, _, _), .paused(let d, _, _), .verifying(let d, _), .finished(let d, _): d
        default: nil
        }
    }
}

extension AppModel {
    private static let downloadSession: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 60
        c.httpAdditionalHeaders = ["User-Agent": "iRufus/\(appVersion)"]
        return URLSession(configuration: c, delegate: HTTPSOnlyRedirects(), delegateQueue: nil)
    }()

    func openDownloads() {
        download.showSheet = true
        if case .idle = download.phase { resolveDownload() }
        if case .failed = download.phase { resolveDownload() }
    }

    /// Look up the current version and checksum of the selected product.
    func resolveDownload() {
        guard !download.isWorking else { return }
        if case .paused = download.phase { discardPartialDownload() }
        downloadGeneration += 1
        let generation = downloadGeneration
        let product = download.product
        download.phase = .resolving
        log.add("Looking up \(product.rawValue) on \(product.publisherHost)")
        Task {
            do {
                let language = product.family == .windows ? download.windowsLanguage : nil
                let d = try await DownloadCatalog.resolve(product, language: language, fetch: Self.fetchMetadata)
                let size = await Self.contentLength(d.url)
                guard generation == downloadGeneration else { return }
                let existing = (try? DownloadCatalog.destination(for: d, in: download.folder))
                    .map { FileManager.default.fileExists(atPath: $0.path) } ?? false
                log.add("\(d.fileName) (\(d.version)), SHA-256 \(d.sha256), \(Self.describe(d.verification))")
                if let l = d.language {
                    download.windowsLanguage = l
                    download.windowsLanguages = d.languages
                }
                download.phase = .ready(d, size: size, existing: existing)
            } catch {
                guard generation == downloadGeneration else { return }
                downloadFailed(error)
            }
        }
    }

    func chooseDownloadFolder(_ url: URL) {
        guard !download.isWorking else { return }
        if case .paused = download.phase { discardPartialDownload() }
        download.folder = url
        if download.resolved != nil { resolveDownload() }
    }

    /// `checkExisting: false` downloads even if a file with the same name is in the folder
    /// (used after that file failed verification).
    func startDownload(checkExisting: Bool = true) {
        let d: ResolvedDownload
        var expected: Int64?
        switch download.phase {
        case .ready(let r, let size, _): d = r; expected = size
        case .paused(let r, _, let total): d = r; expected = total
        default: return
        }
        let destination: URL
        do {
            destination = try DownloadCatalog.destination(for: d, in: download.folder)
        } catch {
            downloadFailed(error)
            return
        }
        // A file with the same name is verified first: if it is the right image, nothing to download.
        if checkExisting, downloadResumeData == nil, FileManager.default.fileExists(atPath: destination.path) {
            log.add("\(destination.lastPathComponent) already exists, verifying it")
            verifyDownload(d, file: destination, destination: destination, downloadIfInvalid: true)
            return
        }
        if let needed = expected {
            for dir in Set([download.folder.standardizedFileURL, FileManager.default.temporaryDirectory.standardizedFileURL]) {
                let available = (try? dir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
                    .volumeAvailableCapacityForImportantUsage ?? Int64.max
                if available < needed {
                    downloadFailed(DownloadError.insufficientSpace(needed: needed, available: available))
                    return
                }
            }
        }
        downloadGeneration += 1
        let generation = downloadGeneration
        let resume = downloadResumeData
        downloadResumeData = nil
        let staging = download.folder.appendingPathComponent(".\(d.fileName).irufus-part")
        download.phase = .downloading(d, received: 0, total: expected, bytesPerSecond: 0)
        // Microsoft's links carry a temporary access token in the query: keep it out of the log.
        let shown = d.url.absoluteString.components(separatedBy: "?")[0]
        log.add(resume == nil ? "Downloading \(shown)" : "Resuming download of \(d.fileName)")

        let started = Date()
        var startBytes: Int64?
        fileDownload = FileDownload(session: Self.downloadSession, url: d.url, resumeData: resume, staging: staging,
            onProgress: { [weak self] received, total in
                guard let self, generation == self.downloadGeneration else { return }
                if startBytes == nil { startBytes = received }
                let elapsed = Date().timeIntervalSince(started)
                let rate = elapsed > 1 ? Double(received - (startBytes ?? 0)) / elapsed : 0
                self.download.phase = .downloading(d, received: received, total: total ?? expected, bytesPerSecond: rate)
            },
            onFinish: { [weak self] result in
                guard let self, generation == self.downloadGeneration else { return }
                self.fileDownload = nil
                switch result {
                case .success(let file):
                    self.verifyDownload(d, file: file, destination: destination, downloadIfInvalid: false)
                case .failure(let failure):
                    if let data = failure.resumeData {
                        self.downloadResumeData = data
                        let received: Int64
                        if case .downloading(_, let r, _, _) = self.download.phase { received = r } else { received = 0 }
                        self.download.phase = .paused(d, received: received, total: expected)
                        if !failure.cancelled {
                            self.log.add("Download interrupted: \(failure.error.localizedDescription); it can be resumed", level: .warning)
                        }
                    } else if failure.cancelled {
                        self.download.phase = .ready(d, size: expected, existing: false)
                    } else {
                        self.downloadFailed(failure.error)
                    }
                }
            })
    }

    /// Pause a download (resumable when the server supports it) or stop a verification.
    func cancelDownload() {
        switch download.phase {
        case .downloading:
            log.add("Download paused")
            fileDownload?.pause()
        case .verifying:
            downloadVerifyCancel?.cancel()
        case .resolving:
            downloadGeneration += 1
            download.phase = .idle
        default:
            break
        }
    }

    /// Forget a paused download and its partial file.
    func discardPartialDownload() {
        guard case .paused(let d, _, let total) = download.phase else { return }
        downloadResumeData = nil
        try? FileManager.default.removeItem(at: download.folder.appendingPathComponent(".\(d.fileName).irufus-part"))
        download.phase = .ready(d, size: total, existing: false)
    }

    func useDownloadedImage() {
        guard case .finished(_, let url) = download.phase, !isBusy else { return }
        download.showSheet = false
        selectImage(url)
    }

    /// Hash `file` with the engine and compare it with the expected SHA-256; on success the
    /// file is moved to `destination`. A mismatch deletes a downloaded file; a file that was
    /// already in the folder is left in place and replaced only once a fresh copy has been
    /// downloaded and verified.
    private func verifyDownload(_ d: ResolvedDownload, file: URL, destination: URL, downloadIfInvalid: Bool) {
        downloadGeneration += 1
        let generation = downloadGeneration
        let cancel = CancelHandle()
        downloadVerifyCancel = cancel
        download.phase = .verifying(d, progress: 0)
        let observer = EngineObserver(onProgress: { p in
            DispatchQueue.main.async {
                guard generation == self.downloadGeneration else { return }
                self.download.phase = .verifying(d, progress: p.fraction ?? 0)
            }
        }, onLog: { _ in })
        let path = file.path
        Task.detached(priority: .userInitiated) {
            let result = Result { try Engine.hashFile(path: path, algorithms: [.sha256], observer: observer, cancel: cancel) }
            // A signed image is accepted only if its signature verifies as well.
            let signature: Result<Void, Error>
            if case .success(let h) = result, h.sha256?.lowercased() == d.sha256,
               case .signedImage(_, let fingerprint) = d.verification {
                signature = Result {
                    guard let sig = d.imageSignature else { throw OpenPGPError.malformed("no signature") }
                    try OpenPGP.verify(detachedSignature: sig, ofFile: file,
                                       keys: DownloadCatalog.pinnedKeys.filter { $0.fingerprint == fingerprint })
                }
            } else {
                signature = .success(())
            }
            await MainActor.run {
                guard generation == self.downloadGeneration else { return }
                self.downloadVerifyCancel = nil
                switch result {
                case .success(let h) where h.sha256?.lowercased() == d.sha256:
                    if case .failure(let e) = signature {
                        self.log.add("\(d.fileName): OpenPGP signature not valid (\(e))", level: .error)
                        if downloadIfInvalid {
                            self.download.phase = .ready(d, size: nil, existing: false)
                            self.startDownload(checkExisting: false)
                        } else {
                            try? FileManager.default.removeItem(at: file)
                            self.downloadFailed(DownloadError.imageSignature(e as? OpenPGPError ?? .badSignature))
                        }
                        return
                    }
                    if case .signedImage = d.verification {
                        self.log.add("\(d.fileName): OpenPGP signature verified")
                    }
                    do {
                        if file != destination {
                            _ = try FileManager.default.replaceItemAt(destination, withItemAt: file)
                        }
                        self.log.add("\(d.fileName): SHA-256 verified, saved to \(destination.path)")
                        self.download.phase = .finished(d, destination)
                    } catch {
                        self.downloadFailed(error)
                    }
                case .success(let h):
                    self.log.add("\(d.fileName): SHA-256 \(h.sha256 ?? "?") does not match \(d.sha256)", level: .error)
                    if downloadIfInvalid {
                        self.log.add("Downloading a fresh copy of \(d.fileName)")
                        self.download.phase = .ready(d, size: nil, existing: false)
                        self.startDownload(checkExisting: false)
                    } else {
                        try? FileManager.default.removeItem(at: file)
                        self.downloadFailed(DownloadError.checksumMismatch)
                    }
                case .failure(let e):
                    if (e as? EngineError)?.code == .cancelled {
                        if !downloadIfInvalid { try? FileManager.default.removeItem(at: file) }
                        self.download.phase = .ready(d, size: nil, existing: downloadIfInvalid)
                    } else {
                        self.downloadFailed(e)
                    }
                }
            }
        }
    }

    private func downloadFailed(_ error: Error) {
        log.add("Download failed: \(error)", level: .error)
        download.phase = .failed(Self.describeDownloadError(error))
    }

    static func describe(_ v: DownloadVerification) -> String {
        switch v {
        case .signedChecksums(let name, let fp): "checksums signed by \(name) (\(fp))"
        case .signedImage(let name, let fp): "image signed by \(name) (\(fp))"
        case .pinnedChecksum: "checksum pinned in iRufus"
        case .publishedChecksum(let page): "checksum published on \(page.absoluteString)"
        }
    }

    static func describeDownloadError(_ error: Error) -> String {
        switch error {
        case DownloadError.refused(let code):
            return String(localized: "Microsoft refused the download request (\(code)). Microsoft sometimes blocks automated downloads, VPNs and some networks: try again later, or download the ISO from Microsoft's page and select it.")
        case DownloadError.signature:
            return String(localized: "The publisher's checksum list does not carry a valid signature. The download was not started.")
        case DownloadError.imageSignature:
            return String(localized: "The downloaded image does not carry a valid signature from its publisher. Do not use it.")
        case DownloadError.checksumMismatch:
            return String(localized: "The downloaded file does not match the publisher's checksum and was deleted. Try again later.")
        case DownloadError.insufficientSpace(let needed, let available):
            return String(localized: "Not enough free space: \(Format.bytes(UInt64(needed))) needed, \(Format.bytes(UInt64(max(available, 0)))) available.")
        case DownloadError.malformedMetadata, DownloadError.notFound:
            return String(localized: "The publisher's site did not list the expected image. iRufus may need an update.")
        case DownloadError.network, is URLError:
            return String(localized: "Could not reach the publisher's server. Check your internet connection.")
        default:
            return String(localized: "The download failed: \(error.localizedDescription)")
        }
    }

    /// HTTPS GET of a small metadata file, refusing anything larger than the catalog's limit.
    private static func fetchMetadata(_ request: URLRequest) async throws -> Data {
        guard let url = request.url, url.scheme == "https" else { throw DownloadError.network("insecure URL") }
        let (bytes, response) = try await downloadSession.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw DownloadError.network("HTTP \(status) for \(url.host ?? "")\(url.path)") }
        var data = Data()
        for try await b in bytes {
            data.append(b)
            if data.count > DownloadCatalog.maxMetadataSize { throw DownloadError.malformedMetadata("file too large") }
        }
        return data
    }

    /// Size announced by the server (HEAD), if any.
    private static func contentLength(_ url: URL) async -> Int64? {
        var req = URLRequest(url: url)
        req.httpMethod = "HEAD"
        guard let (_, response) = try? await downloadSession.data(for: req),
              let http = response as? HTTPURLResponse, http.statusCode == 200, http.expectedContentLength > 0
        else { return nil }
        return http.expectedContentLength
    }
}

/// Refuses redirects that would leave HTTPS.
final class HTTPSOnlyRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url?.scheme == "https" ? request : nil)
    }
}

/// One image download through a download task, so that it can be paused and resumed.
/// Callbacks arrive on the main queue. The finished file is moved to `staging`.
final class FileDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    struct Failure: Error {
        let error: Error
        let resumeData: Data?
        let cancelled: Bool
    }

    private var task: URLSessionDownloadTask!
    private let staging: URL
    private let onProgress: (Int64, Int64?) -> Void
    private let onFinish: (Result<URL, Failure>) -> Void
    private var lastReport = Date.distantPast
    private var finished: URL?
    private var finishError: Error?

    init(session: URLSession, url: URL, resumeData: Data?, staging: URL,
         onProgress: @escaping (Int64, Int64?) -> Void, onFinish: @escaping (Result<URL, Failure>) -> Void) {
        self.staging = staging
        self.onProgress = onProgress
        self.onFinish = onFinish
        super.init()
        task = resumeData.map { session.downloadTask(withResumeData: $0) } ?? session.downloadTask(with: url)
        task.delegate = self
        task.resume()
    }

    func pause() {
        task.cancel(byProducingResumeData: { _ in })  // the data arrives in didCompleteWithError
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url?.scheme == "https" ? request : nil)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let now = Date()
        guard now.timeIntervalSince(lastReport) >= 0.2 else { return }
        lastReport = now
        let total: Int64? = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil
        DispatchQueue.main.async { self.onProgress(totalBytesWritten, total) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The temporary file disappears when this method returns: move it now.
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 || status == 206 else {
            finishError = DownloadError.network("HTTP \(status)")
            return
        }
        do {
            try? FileManager.default.removeItem(at: staging)
            try FileManager.default.moveItem(at: location, to: staging)
            // URLSession's temporary file is private (0600); give it the usual permissions of a download.
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: staging.path)
            finished = staging
        } catch {
            finishError = error
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let result: Result<URL, Failure>
        if let error {
            let ns = error as NSError
            result = .failure(Failure(error: error,
                                      resumeData: ns.userInfo[NSURLSessionDownloadTaskResumeData] as? Data,
                                      cancelled: ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled))
        } else if let finished {
            result = .success(finished)
        } else {
            result = .failure(Failure(error: finishError ?? DownloadError.network("no data"), resumeData: nil, cancelled: false))
        }
        DispatchQueue.main.async { self.onFinish(result) }
    }
}
