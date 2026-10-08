// Typed Swift wrapper around the Rust engine's C ABI (engine/include/irufus.h).

import CIrufus
import Foundation

public enum EngineErrorCode: UInt32, Sendable {
    case io = 1
    case cancelled = 2
    case invalidArgument = 3
    case unsupportedImage = 4
    case corruptImage = 5
    case insufficientSpace = 6
    case deviceMismatch = 7
    case deviceGone = 8
    case verifyFailed = 9
    case fileTooLarge = 10
    case unsupported = 11
    case badBlocksFound = 12
    case `internal` = 99
}

public struct EngineError: Error, Sendable, Equatable {
    public let code: EngineErrorCode
    /// English diagnostic from the engine (logged; the UI shows a localised summary).
    public let message: String

    public init(code: EngineErrorCode, message: String) {
        self.code = code
        self.message = message
    }
}

public enum EnginePhase: UInt32, Sendable {
    case preparing = 0, hashing, partitioning, formatting, writing, copyingFiles, splittingWim,
         syncing, verifying, badBlocks, reading, zeroing, finalizing
}

public struct EngineProgress: Sendable, Equatable {
    public let phase: EnginePhase
    public let done: UInt64
    public let total: UInt64
    public let bytesPerSecond: Double

    public var fraction: Double? {
        total > 0 ? min(1, Double(done) / Double(total)) : nil
    }

    /// Seconds remaining, if it can be estimated.
    public var eta: TimeInterval? {
        guard total > done, bytesPerSecond > 1 else { return nil }
        return Double(total - done) / bytesPerSecond
    }
}

/// Receives progress and log lines from a running engine call (on the calling thread).
public final class EngineObserver: @unchecked Sendable {
    let onProgress: (EngineProgress) -> Void
    let onLog: (String) -> Void

    public init(onProgress: @escaping (EngineProgress) -> Void, onLog: @escaping (String) -> Void) {
        self.onProgress = onProgress
        self.onLog = onLog
    }

    public static let silent = EngineObserver(onProgress: { _ in }, onLog: { _ in })
}

/// Cooperative cancellation shared with the engine.
public final class CancelHandle: @unchecked Sendable {
    let raw: OpaquePointer

    public init() {
        raw = irufus_cancel_new()
    }

    public func cancel() {
        irufus_cancel_trigger(raw)
    }

    deinit {
        irufus_cancel_free(raw)
    }
}

/// A raw disk opened through the privileged broker. Owns the descriptor.
public final class EngineDevice: @unchecked Sendable {
    let raw: OpaquePointer

    /// Takes ownership of `fd` (closed on failure too).
    public init(fd: Int32, expectedSize: UInt64, expectedBlockSize: UInt32) throws {
        var err = IrufusError(code: 0, message: nil)
        guard let d = irufus_device_from_fd(fd, expectedSize, expectedBlockSize, &err) else {
            throw Engine.takeError(&err)
        }
        raw = d
    }

    deinit {
        irufus_device_close(raw)
    }
}

public enum Engine {
    public static var abiVersion: UInt32 { irufus_abi_version() }

    public static var version: String {
        guard let s = irufus_engine_version() else { return "?" }
        defer { irufus_string_free(s) }
        return String(cString: s)
    }

    static func takeError(_ err: inout IrufusError) -> EngineError {
        let message = err.message.map { String(cString: $0) } ?? "unknown error"
        if let m = err.message {
            irufus_string_free(m)
        }
        return EngineError(code: EngineErrorCode(rawValue: err.code) ?? .internal, message: message)
    }

    /// Invoke an engine function returning an owned JSON string.
    static func call(_ body: (UnsafeMutablePointer<IrufusError>) -> UnsafeMutablePointer<CChar>?) throws -> String {
        var err = IrufusError(code: 0, message: nil)
        guard let out = body(&err) else {
            throw takeError(&err)
        }
        defer { irufus_string_free(out) }
        return String(cString: out)
    }

    static func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: Data(json.utf8))
        } catch {
            throw EngineError(code: .internal, message: "cannot decode engine response: \(error)")
        }
    }

    static func encode<T: Encodable>(_ value: T) throws -> String {
        let data = try JSONEncoder().encode(value)
        return String(decoding: data, as: UTF8.self)
    }

    /// Run `body` with C callbacks bound to `observer`.
    static func withCallbacks<R>(_ observer: EngineObserver, _ body: (IrufusCallbacks) throws -> R) rethrows -> R {
        let box = Unmanaged.passRetained(observer)
        defer { box.release() }
        let progress: IrufusProgressFn = { ctx, phase, done, total, rate in
            guard let ctx else { return }
            let o = Unmanaged<EngineObserver>.fromOpaque(ctx).takeUnretainedValue()
            o.onProgress(EngineProgress(phase: EnginePhase(rawValue: phase) ?? .preparing, done: done, total: total, bytesPerSecond: rate))
        }
        let log: IrufusLogFn = { ctx, message in
            guard let ctx, let message else { return }
            let o = Unmanaged<EngineObserver>.fromOpaque(ctx).takeUnretainedValue()
            o.onLog(String(cString: message))
        }
        return try body(IrufusCallbacks(ctx: box.toOpaque(), progress: progress, log: log))
    }

    // MARK: - API

    public static func analyze(path: String) throws -> ImageReport {
        let json = try call { irufus_analyze(path, $0) }
        let report = try decode(ImageReport.self, json)
        guard report.schemaVersion == ImageReport.supportedSchemaVersion else {
            throw EngineError(code: .internal, message: "unsupported report schema \(report.schemaVersion)")
        }
        return report
    }

    public static func hashFile(path: String, algorithms: Set<HashAlgorithm>, observer: EngineObserver,
                                cancel: CancelHandle) throws -> HashResult {
        let mask = algorithms.reduce(UInt32(0)) { $0 | $1.mask }
        let json = try withCallbacks(observer) { cb in
            try call { irufus_hash_file(path, mask, cb, cancel.raw, $0) }
        }
        return try decode(HashResult.self, json)
    }

    public static func parseChecksum(_ input: String) -> ParsedChecksum? {
        guard let json = try? call({ irufus_parse_checksum(input, $0) }) else { return nil }
        return try? decode(ParsedChecksum.self, json)
    }

    public static func write(device: EngineDevice, imagePath: String, request: WriteRequest,
                             observer: EngineObserver, cancel: CancelHandle) throws -> WriteSummary {
        let req = try encode(request)
        let json = try withCallbacks(observer) { cb in
            try call { irufus_write_image(device.raw, imagePath, req, cb, cancel.raw, $0) }
        }
        switch request.mode {
        case .dd: return .dd(try decode(DdSummary.self, json))
        case .isoExtract: return .extract(try decode(ExtractSummary.self, json))
        }
    }

    public static func zero(device: EngineDevice, verify: Bool, observer: EngineObserver, cancel: CancelHandle) throws {
        _ = try withCallbacks(observer) { cb in
            try call { irufus_zero_device(device.raw, verify, cb, cancel.raw, $0) }
        }
    }

    public static func badBlocks(device: EngineDevice, passes: UInt32, observer: EngineObserver,
                                 cancel: CancelHandle) throws -> BadBlocksReport {
        let json = try withCallbacks(observer) { cb in
            try call { irufus_bad_blocks(device.raw, passes, cb, cancel.raw, $0) }
        }
        return try decode(BadBlocksReport.self, json)
    }

    public enum SaveFormat: UInt32, Sendable { case raw = 0, vhd = 1 }

    public static func save(device: EngineDevice, to path: String, format: SaveFormat, observer: EngineObserver,
                            cancel: CancelHandle) throws -> SaveSummary {
        let json = try withCallbacks(observer) { cb in
            try call { irufus_save_device(device.raw, path, format.rawValue, cb, cancel.raw, $0) }
        }
        return try decode(SaveSummary.self, json)
    }

    public static func fat32Options(deviceBytes: UInt64, blockSize: UInt32, scheme: PartitionScheme) throws -> Fat32Options {
        let json = try call { irufus_fat32_options(deviceBytes, blockSize, scheme == .mbr ? 0 : 1, $0) }
        return try decode(Fat32Options.self, json)
    }

    /// The answer file that would be written, or nil when no option is selected.
    public static func answerFilePreview(_ options: WueOptions) throws -> AnswerFilePreview? {
        let request = try encode(options)
        let json = try call { irufus_wue_preview(request, $0) }
        if json == "{}" { return nil }
        return try decode(AnswerFilePreview.self, json)
    }

    public static func sanitizeAccountName(_ name: String) throws -> String {
        try call { irufus_sanitize_account_name(name, $0) }
    }
}
