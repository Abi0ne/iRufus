// iRufus — SPDX-License-Identifier: GPL-3.0-or-later
// Operating systems iRufus can download. Every image comes from the publisher's own
// HTTPS server and is accepted only if its SHA-256 matches a value that is either
// pinned here (fixed releases) or read from a checksum list whose OpenPGP signature
// verifies with a key pinned here, or if the image itself carries such a signature.
// See docs/SICUREZZA.md.

import Foundation

public enum DownloadProduct: String, CaseIterable, Identifiable, Sendable {
    case ubuntuDesktop
    case systemRescue
    case freeDOSLite
    case freeDOSFull

    public var id: String { rawValue }

    public enum Family: Sendable { case linux, dos }

    public var family: Family {
        switch self {
        case .ubuntuDesktop, .systemRescue: .linux
        case .freeDOSLite, .freeDOSFull: .dos
        }
    }

    /// Host the image and its checksums come from, for display.
    public var publisherHost: String {
        switch self {
        case .ubuntuDesktop: "releases.ubuntu.com"
        case .systemRescue: "fastly-cdn.system-rescue.org"
        case .freeDOSLite, .freeDOSFull: "www.ibiblio.org"
        }
    }
}

public enum DownloadVerification: Equatable, Sendable {
    /// Checksum list signed with this pinned key.
    case signedChecksums(keyName: String, fingerprint: String)
    /// The image itself is signed with this pinned key (checked after the download);
    /// the SHA-256 published next to it only guards against transfer errors.
    case signedImage(keyName: String, fingerprint: String)
    /// Checksum pinned in iRufus for a fixed release.
    case pinnedChecksum
}

public struct ResolvedDownload: Equatable, Sendable {
    public let product: DownloadProduct
    public let version: String
    public let fileName: String
    public let url: URL
    /// Lowercase hex.
    public let sha256: String
    public let verification: DownloadVerification
    /// Detached signature of the image, for `.signedImage`.
    public var imageSignature: Data?
}

public enum DownloadError: Error, Equatable, Sendable {
    case network(String)
    case malformedMetadata(String)
    case signature(OpenPGPError)
    case notFound(String)
    case checksumMismatch
    case imageSignature(OpenPGPError)
    case insufficientSpace(needed: Int64, available: Int64)
}

public enum DownloadCatalog {
    /// Upper bound for metadata files (release lists, checksum lists, signatures).
    public static let maxMetadataSize = 1 << 20

    public static let ubuntuKey = OpenPGPKey(
        name: "Ubuntu CD Image Automatic Signing Key (2012)",
        fingerprint: "843938DF228D22F7B3742BC0D94AA3F0EFE21092",
        packet: "BE+tjmgBEAC7pKK78t89DW7mvMoSgiScLfPNF8/TSF380is0hFRL3dOmcXEfNsX26jtv8bdvvtkElB1fPwOntmqSAsrLOuURVQ6GSxH7IDU5QFfaTIsudtLR5YTlC3ZuOTOb1HWEK26fDRXuIWjhFDXJH3KLv+rSrq0+x7ZtH++CHq5XJWk7VUh/wWcGxZefs7+1HTivymhjXCOwQvqblzZ5MAec9i4QIXxkqX1HY7ryxGVdjj9lApOnoU5EcSYr08cm7xQEgrdDLAZFQxDYBLDuV6E6jKEfAfwZINSEe4Ocm82vtCF5K0HiwhFU09ky2yogbMuTTi2f8ibN8SbbhZDJlDPd2ZkkpsKNfIALmOiPhHGvXGmtg6FdzRUOSGirSm8tcakpS+d0/IElbD453sksxg6s3cTs7Q+PudaccyQ0BqatMnzmfxCVOotT65kVnmz2P+4Q0gRSQ/Zi9Inz+OrzWxtn6/Tdw+FMUwvBccxW1r88k6uVLz23jW/8jOuwnUp4JKmZta/U2UZKTyPyrvTYhp/zK332BEnxiRY4ZfQjA4Iwlw00l4pYBDLLc6TFJtLbDv859UCisXa8MtWYWrlM3YfGFs9k1WemML8u79g2DK8g3VPkD94Q5anqufEGm74K/keOmss8cQoBX9VPFMpS1mFCT+2UdGP0UvMlADct0aFnAwtb9QARAQAB"
    )

    /// Signing subkey of "Francois Dupoux 20210704" (primary key
    /// 0FF1 1AF0 81E9 8345 5948 1203 7091 115F 8320 B897), from
    /// https://www.system-rescue.org/security/signing-keys/ and keyserver.ubuntu.com.
    public static let systemRescueKey = OpenPGPKey(
        name: "SystemRescue (Francois Dupoux, 2021)",
        fingerprint: "62989046EB5C7E985ECDF5DD3B0FEA9BE13CA3C9",
        packet: "BGDhtFgBEADCM/+79Ql8jida/6maU/sHd8qMAjmTkEWVVH4EFqdst6OjLvVdSd0FpFq+zpaQGx+w0p2kjTXw/dr8kuYNXLO/mCud0aqcRpFyZk1KX2e/QX4Tkx3kTEXxQRYdV9efd6oLbVO+rej0lNss/4kCDsH6Zhu2qNQfgznOUfZuwr67aklBqxAdgfEo4steBL003Jclj5/at0vXxTWlLY4fgmz+PVssPlU65012z+H9B60LyUJOJgrv8tNzokx3j2zBcIkUcDDGAluXcVfekFqLWJIMwx56kQzQE4Fs1xPhvzr7w5akIC9OHQsJ+EX5JEX74jrtzA8SuHnUNupRIzWKO6Lm8XBelOET4IHmU0uYeCdrZp1YsjJ3UiC7ai6imIPB8O0Oepb5ZyTDzER/Q1jvPdLxUjMaM34CLeSE5PIKpKggWqAompXaZ6vNItw4tNUPSiAjCjzJ85t2L0OOTwXE+9V+4x+0SPlfnkD+C5PBccyfiXZVecvOyBIiB0Yc6xYyKYIZ0EmqfWSFZJ/YlsbZKkRQh+IowqUExfxeZwcowxq10I+NZUWeaEhTOCkdeTYQiqqcqT5bwxBVBQnKzb0Pn7qMJui/Vg+MZsl0fL+er0nQDBb/+iFnGusv0Ny132hhD2LjRAmevii8jiO7oPhl8u+oRT6g1AfuIGbMxwQeWBRDzwARAQAB"
    )

    public static var pinnedKeys: [OpenPGPKey] { [ubuntuKey, systemRescueKey] }

    static let systemRescueDownloadPage = URL(string: "https://www.system-rescue.org/Download/")!
    static let systemRescueSite = "https://www.system-rescue.org/releases"
    static let systemRescueCDN = "https://fastly-cdn.system-rescue.org/releases"
    /// Oldest release offered: an older (still validly signed) image is never proposed.
    static let systemRescueMinimum = AppVersion("13.02")!

    static let ubuntuMetaRelease = URL(string: "https://changelogs.ubuntu.com/meta-release-lts")!
    static let ubuntuReleases = "https://releases.ubuntu.com"
    static let freeDOSBase = "https://www.ibiblio.org/pub/micro/pc-stuff/freedos/files/distributions/1.4"

    /// Find the image to download. `fetch` returns the body of an HTTPS GET (at most
    /// `maxMetadataSize` bytes) and is injected so that the resolution can be tested offline.
    public static func resolve(_ product: DownloadProduct, fetch: (URL) async throws -> Data) async throws -> ResolvedDownload {
        switch product {
        case .ubuntuDesktop:
            let series = try latestUbuntuLTS(try await fetch(ubuntuMetaRelease))
            let dir = "\(ubuntuReleases)/\(series)"
            let sums = try await fetch(URL(string: "\(dir)/SHA256SUMS")!)
            let sig = try await fetch(URL(string: "\(dir)/SHA256SUMS.gpg")!)
            do {
                try OpenPGP.verify(detachedSignature: sig, of: sums, keys: [ubuntuKey])
            } catch let e as OpenPGPError {
                throw DownloadError.signature(e)
            }
            let (file, version, hash) = try latestUbuntuDesktop(parseChecksums(sums))
            return ResolvedDownload(product: product, version: version, fileName: file,
                                    url: URL(string: "\(dir)/\(file)")!, sha256: hash,
                                    verification: .signedChecksums(keyName: ubuntuKey.name, fingerprint: ubuntuKey.fingerprint))
        case .systemRescue:
            let version = try latestSystemRescue(try await fetch(systemRescueDownloadPage))
            let file = "systemrescue-\(version)-amd64.iso"
            let sums = try parseChecksums(try await fetch(URL(string: "\(systemRescueSite)/\(version)/\(file).sha256")!))
            guard let hash = sums[file] else { throw DownloadError.notFound(file) }
            let sig = try await fetch(URL(string: "\(systemRescueSite)/\(version)/\(file).asc")!)
            // Reject a signature that iRufus could not check before downloading 1.3 GB.
            do {
                let parsed = try OpenPGP.parseSignature(try OpenPGP.dearmor(sig))
                guard parsed.issuers.contains(systemRescueKey.fingerprint)
                        || parsed.issuerKeyIDs.contains(String(systemRescueKey.fingerprint.suffix(16)))
                else { throw OpenPGPError.unknownKey }
            } catch let e as OpenPGPError {
                throw DownloadError.signature(e)
            }
            return ResolvedDownload(product: product, version: version, fileName: file,
                                    url: URL(string: "\(systemRescueCDN)/\(version)/\(file)")!, sha256: hash,
                                    verification: .signedImage(keyName: systemRescueKey.name, fingerprint: systemRescueKey.fingerprint),
                                    imageSignature: sig)
        case .freeDOSLite:
            // https://www.ibiblio.org/pub/micro/pc-stuff/freedos/files/distributions/1.4/verify.txt
            return freeDOS(product, file: "FD14-LiteUSB.zip",
                           sha256: "857dcd2ebf9d3d094320154db5fb5b830acba6fb98f981a95a0ca7ab3350338b")
        case .freeDOSFull:
            return freeDOS(product, file: "FD14-FullUSB.zip",
                           sha256: "cd440cd165f5a8a184870cb615f525af182660c15f9bcf1e9d198ca19cedcaff")
        }
    }

    private static func freeDOS(_ product: DownloadProduct, file: String, sha256: String) -> ResolvedDownload {
        ResolvedDownload(product: product, version: "1.4", fileName: file, url: URL(string: "\(freeDOSBase)/\(file)")!,
                         sha256: sha256, verification: .pinnedChecksum)
    }

    /// Code name of the newest supported LTS in Ubuntu's meta-release-lts file
    /// (RFC 822-style stanzas: "Dist: noble", "Version: 24.04.5 LTS", "Supported: 1").
    static func latestUbuntuLTS(_ data: Data) throws -> String {
        let text = String(decoding: data, as: UTF8.self)
        var best: (dist: String, version: AppVersion)?
        for stanza in text.components(separatedBy: "\n\n") {
            var fields: [String: String] = [:]
            for line in stanza.split(separator: "\n") {
                guard let colon = line.firstIndex(of: ":") else { continue }
                fields[String(line[..<colon])] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            guard fields["Supported"] == "1", let dist = fields["Dist"],
                  dist.range(of: #"^[a-z]{2,32}$"#, options: .regularExpression) != nil,
                  let v = fields["Version"]?.split(separator: " ").first.flatMap({ AppVersion(String($0)) })
            else { continue }
            if best.map({ v > $0.version }) ?? true { best = (dist, v) }
        }
        guard let best else { throw DownloadError.malformedMetadata("no supported LTS release") }
        return best.dist
    }

    /// Newest "systemrescue-<major>.<minor>-amd64.iso" linked from the download page,
    /// not older than `systemRescueMinimum`.
    static func latestSystemRescue(_ page: Data) throws -> String {
        let html = String(decoding: page, as: UTF8.self)
        var best: (label: String, version: AppVersion)?
        for m in html.matches(of: #/systemrescue-([0-9]{1,3}\.[0-9]{1,3})-amd64\.iso/#) {
            guard let v = AppVersion(String(m.1)), v >= systemRescueMinimum else { continue }
            if best.map({ v > $0.version }) ?? true { best = (String(m.1), v) }
        }
        guard let best else { throw DownloadError.notFound("SystemRescue amd64 image") }
        return best.label
    }

    /// "<sha256> *<file>" or "<sha256>  <file>" lines → [file: hash].
    static func parseChecksums(_ data: Data) throws -> [String: String] {
        var out: [String: String] = [:]
        for line in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let hash = parts[0].lowercased()
            let name = parts[1].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "*"))
            guard hash.count == 64, hash.allSatisfy(\.isHexDigit),
                  name.range(of: #"^[A-Za-z0-9._+-]{1,255}$"#, options: .regularExpression) != nil
            else { continue }
            out[name] = hash
        }
        guard !out.isEmpty else { throw DownloadError.malformedMetadata("empty checksum list") }
        return out
    }

    /// Newest "ubuntu-<version>-desktop-amd64.iso" (a series directory can list both
    /// 26.04 and 26.04.1).
    static func latestUbuntuDesktop(_ sums: [String: String]) throws -> (file: String, version: String, sha256: String) {
        var best: (file: String, label: String, version: AppVersion, hash: String)?
        for (file, hash) in sums {
            guard let m = file.firstMatch(of: #/^ubuntu-([0-9]+\.[0-9]+(?:\.[0-9]+)?)-desktop-amd64\.iso$/#),
                  let v = AppVersion(String(m.1))
            else { continue }
            // AppVersion normalises "04" to "4": keep the published spelling for display.
            if best.map({ v > $0.version }) ?? true { best = (file, String(m.1), v, hash) }
        }
        guard let best else { throw DownloadError.notFound("Ubuntu Desktop amd64 image") }
        return (best.file, best.label, best.hash)
    }

    /// Where a download lands: `folder/fileName`, refusing anything that is not a plain name.
    public static func destination(for d: ResolvedDownload, in folder: URL) throws -> URL {
        let name = d.fileName
        guard name.range(of: #"^[A-Za-z0-9][A-Za-z0-9._+-]{0,254}$"#, options: .regularExpression) != nil else {
            throw DownloadError.malformedMetadata("file name")
        }
        return folder.appendingPathComponent(name, isDirectory: false)
    }
}
