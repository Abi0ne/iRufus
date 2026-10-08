// Swift mirrors of the JSON documents produced by the Rust engine (schema v1).
// Field names follow engine/src (serde camelCase). See docs/FFI.md.

import Foundation

public enum WriteMode: String, Codable, Sendable, CaseIterable {
    case dd
    case isoExtract
}

public enum PartitionScheme: String, Codable, Sendable, CaseIterable {
    case mbr
    case gpt
}

public enum ImageKind: String, Codable, Sendable {
    case iso
    case diskImage
}

public struct Note: Codable, Sendable, Hashable {
    public enum Level: String, Codable, Sendable { case info, warning, error }
    public let level: Level
    public let code: String
    public let args: [String]
}

public struct SourceContainer: Codable, Sendable, Hashable {
    public let kind: String
    public let entry: String?
    public let method: String?
}

public struct SourceInfo: Codable, Sendable, Hashable {
    public let container: SourceContainer
    public let fileSize: UInt64
    public let dataSize: UInt64?
    public let sizeIsExact: Bool
}

public struct PartitionInfo: Codable, Sendable, Hashable {
    public let index: UInt32
    public let start: UInt64
    public let size: UInt64
    public let typeId: String
    public let name: String?
    public let bootable: Bool
}

public struct Layout: Codable, Sendable, Hashable {
    public let scheme: PartitionScheme?
    public let partitions: [PartitionInfo]
    public let hasBootSignature: Bool
    public let hasMbrBootCode: Bool
}

public struct ElTorito: Codable, Sendable, Hashable {
    public let biosBootable: Bool
    public let efiBootable: Bool
}

public struct FileRef: Codable, Sendable, Hashable {
    public let path: String
    public let size: UInt64
}

public struct EfiLoader: Codable, Sendable, Hashable {
    public let path: String
    public let arch: String
}

public struct WimImageInfo: Codable, Sendable, Hashable {
    public let index: UInt32
    public let name: String
    public let edition: String?
    public let arch: String?
    public let build: UInt32?
    public let languages: [String]
}

public struct WimInfo: Codable, Sendable, Hashable {
    public let imageCount: UInt32
    public let images: [WimImageInfo]
    public let solid: Bool
    public let spanned: Bool
}

public struct WindowsReport: Codable, Sendable, Hashable {
    public let installImage: FileRef?
    public let wim: WimInfo?
    public let isWindows11: Bool
    public let needsWimSplit: Bool
    public let hasBootWim: Bool
    public let hasExistingAnswerFile: Bool
    public let unattendArch: String?
}

public struct LinuxReport: Codable, Sendable, Hashable {
    public let distroHint: String?
    public let casper: Bool
    public let debianLive: Bool
    public let syslinux: Bool
    public let grub: Bool
}

public struct IsoReport: Codable, Sendable, Hashable {
    public let treeSource: String
    public let hasJoliet: Bool
    public let hasRockRidge: Bool
    public let hasUdf: Bool
    public let elTorito: ElTorito
    public let isohybrid: Bool
    public let fileCount: UInt64
    public let dirCount: UInt64
    public let totalFileBytes: UInt64
    public let largestFile: FileRef?
    public let oversizedFiles: [FileRef]
    public let efiLoaders: [EfiLoader]
    public let windows: WindowsReport?
    public let linux: LinuxReport?
}

public struct ImageReport: Codable, Sendable, Hashable {
    public static let supportedSchemaVersion: UInt32 = 1
    public let schemaVersion: UInt32
    public let path: String
    public let fileName: String
    public let source: SourceInfo
    public let kind: ImageKind
    public let label: String?
    public let imageSize: UInt64?
    public let iso: IsoReport?
    public let layout: Layout?
    public let architectures: [String]
    public let modes: [WriteMode]
    public let recommendedMode: WriteMode?
    public let ddTargets: [String]
    public let extractTargets: [String]
    public let notes: [Note]
}

public struct HashResult: Codable, Sendable, Hashable {
    public let md5: String?
    public let sha1: String?
    public let sha256: String?
    public let sha512: String?

    public func value(for algorithm: HashAlgorithm) -> String? {
        switch algorithm {
        case .md5: md5
        case .sha1: sha1
        case .sha256: sha256
        case .sha512: sha512
        }
    }
}

public enum HashAlgorithm: String, Codable, Sendable, CaseIterable, Identifiable {
    case md5, sha1, sha256, sha512
    public var id: String { rawValue }
    public var mask: UInt32 {
        switch self {
        case .md5: 1
        case .sha1: 2
        case .sha256: 4
        case .sha512: 8
        }
    }
    public var displayName: String {
        switch self {
        case .md5: "MD5"
        case .sha1: "SHA-1"
        case .sha256: "SHA-256"
        case .sha512: "SHA-512"
        }
    }
}

public struct ParsedChecksum: Codable, Sendable, Hashable {
    public let digest: String
    public let algorithm: HashAlgorithm
}

public struct DdSummary: Codable, Sendable, Hashable {
    public let bytesWritten: UInt64
    public let sha256: String
    public let verified: Bool
}

public struct ExtractSummary: Codable, Sendable, Hashable {
    public let label: String
    public let filesCopied: UInt64
    public let bytesCopied: UInt64
    public let wimParts: [String]
    public let patchedFiles: [String]
    public let answerFile: String?
    public let skipped: [String]
    public let verified: Bool
}

public struct BadBlocksReport: Codable, Sendable, Hashable {
    public let passes: UInt32
    public let bytesTested: UInt64
    public let badSectors: UInt64
    public let readErrors: UInt64
    public let writeErrors: UInt64
    public let corruptionErrors: UInt64
    public let badRanges: [[UInt64]]
    public let addressMismatches: UInt64
    public let fakeCapacitySuspected: Bool
    public let firstBadOffset: UInt64?
}

public struct SaveSummary: Codable, Sendable, Hashable {
    public let bytesRead: UInt64
    public let sha256: String
    public let fileSize: UInt64
}

public struct Fat32Options: Codable, Sendable, Hashable {
    public let `default`: UInt32
    public let valid: [UInt32]
    public let partitionBytes: UInt64
}

public struct LocaleSettings: Codable, Sendable, Hashable {
    public var inputLocale: String
    public var systemLocale: String
    public var userLocale: String
    public var uiLanguage: String

    public init(inputLocale: String, systemLocale: String, userLocale: String, uiLanguage: String) {
        self.inputLocale = inputLocale
        self.systemLocale = systemLocale
        self.userLocale = userLocale
        self.uiLanguage = uiLanguage
    }

    /// Regional settings of this Mac, expressed as Windows locale names (e.g. "it-IT").
    public static func current(locale: Locale = .current) -> LocaleSettings? {
        guard let lang = locale.language.languageCode?.identifier,
              let region = locale.region?.identifier else { return nil }
        let name = "\(lang)-\(region)"
        let ui = Locale.preferredLanguages.first.map { Locale(identifier: $0) }
        let uiName = ui.flatMap { l -> String? in
            guard let c = l.language.languageCode?.identifier else { return nil }
            return "\(c)-\(l.region?.identifier ?? region)"
        } ?? name
        return LocaleSettings(inputLocale: name, systemLocale: name, userLocale: name, uiLanguage: uiName)
    }
}

public struct WueOptions: Codable, Sendable, Hashable {
    public var arch: String
    public var bypassRequirements = false
    public var noOnlineAccount = false
    public var localAccount: String?
    public var disableDataCollection = false
    public var locale: LocaleSettings?
    public var disableBitlocker = false

    public init(arch: String) {
        self.arch = arch
    }

    public var isEmpty: Bool {
        !(bypassRequirements || noOnlineAccount || localAccount != nil || disableDataCollection
            || locale != nil || disableBitlocker)
    }
}

public struct WriteRequest: Codable, Sendable, Hashable {
    public var mode: WriteMode
    public var verify: Bool
    public var scheme: PartitionScheme?
    public var clusterSize: UInt32?
    public var label: String?
    public var wue: WueOptions?

    public init(mode: WriteMode, verify: Bool, scheme: PartitionScheme? = nil, clusterSize: UInt32? = nil,
                label: String? = nil, wue: WueOptions? = nil) {
        self.mode = mode
        self.verify = verify
        self.scheme = scheme
        self.clusterSize = clusterSize
        self.label = label
        self.wue = wue
    }
}

public enum WriteSummary: Sendable, Hashable {
    case dd(DdSummary)
    case extract(ExtractSummary)
}

public struct AnswerFilePreview: Codable, Sendable, Hashable {
    public let path: String
    public let xml: String
}
