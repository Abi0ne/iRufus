// iRufus — SPDX-License-Identifier: GPL-3.0-or-later
// Windows 11 ISO from Microsoft's own download service, the one behind
// https://www.microsoft.com/software-download/windows11 (the same protocol as Fido,
// which Rufus uses). The edition ID and the SHA-256 of every language are read from
// that HTTPS page; the ISO is accepted only if its SHA-256 matches. Microsoft
// signs neither the page nor the ISO as a whole, so this is the same check a user
// makes by hand with Get-FileHash. See docs/SICUREZZA.md.

import Foundation

/// One language Microsoft offers for an edition.
public struct WindowsLanguage: Identifiable, Equatable, Hashable, Sendable {
    /// English name, as used by the API ("Italian", "English (United Kingdom)").
    public let name: String
    public let localizedName: String
    public let skuID: String
    public var id: String { name }
}

public enum WindowsDownload {
    static let profile = "606624d44113"
    static let orgID = "y6jn8c31"
    static let instanceID = "560dc9f3-1aa5-4a2f-b63c-9e18f8d0e175"
    static let connector = "https://www.microsoft.com/software-download-connector/api"

    public static func pageURL(_ product: DownloadProduct) -> URL {
        URL(string: product == .windows11ARM
            ? "https://www.microsoft.com/en-us/software-download/windows11arm64"
            : "https://www.microsoft.com/en-us/software-download/windows11")!
    }

    static func resolve(_ product: DownloadProduct, language: String?, fetch: MetadataFetch) async throws -> ResolvedDownload {
        let page = pageURL(product)
        let info = try parsePage(try await fetch(URLRequest(url: page)))
        let session = UUID().uuidString.lowercased()

        // Microsoft's download "protection": the session must be whitelisted, then go
        // through the ov-df fingerprinting exchange, before the API answers.
        _ = try await fetch(URLRequest(url: URL(string: "https://vlscppe.microsoft.com/tags?org_id=\(orgID)&session_id=\(session)")!))
        let mdt = try await fetch(URLRequest(url: URL(string: "https://ov-df.microsoft.com/mdt.js?instanceId=\(instanceID)&PageId=si&session_id=\(session)")!))
        let (w, rticks) = try parseMdt(mdt)
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        _ = try await fetch(URLRequest(url: URL(string: "https://ov-df.microsoft.com/?session_id=\(session)&CustomerId=\(instanceID)&PageId=si&w=\(w)&mdt=\(now)&rticks=\(rticks)")!))

        let skus = try await fetch(URLRequest(url: URL(string:
            "\(connector)/getskuinformationbyproductedition?profile=\(profile)&productEditionId=\(info.editionID)&SKU=undefined&friendlyFileName=undefined&Locale=en-US&sessionID=\(session)")!))
        let languages = try parseSkus(skus)
        let chosen = language.flatMap { l in languages.first { $0.name == l } }
            ?? languages.first { $0.name == defaultLanguage(Locale.current, available: languages) }!
        guard let sha256 = info.hashes[hashKey(chosen.name)] else { throw DownloadError.notFound("SHA-256 of \(chosen.name)") }

        var req = URLRequest(url: URL(string:
            "\(connector)/GetProductDownloadLinksBySku?profile=\(profile)&productEditionId=undefined&SKU=\(chosen.skuID)&friendlyFileName=undefined&Locale=en-US&sessionID=\(session)")!)
        req.setValue(page.absoluteString, forHTTPHeaderField: "Referer")
        let link = try parseLinks(try await fetch(req))

        let build = link.displayName.firstMatch(of: #/\b([0-9]{5}\.[0-9]{1,5})\b/#).map { String($0.1) }
        let version = [info.release, build.map { "build \($0)" }].compactMap { $0 }.joined(separator: " — ")
        var d = ResolvedDownload(product: product, version: version.isEmpty ? link.displayName : version,
                                 fileName: link.url.lastPathComponent, url: link.url, sha256: sha256,
                                 verification: .publishedChecksum(page: page))
        d.languages = languages
        d.language = chosen.name
        return d
    }

    struct PageInfo: Equatable {
        let editionID: String
        let release: String?
        /// `hashKey(language)` → lowercase SHA-256.
        let hashes: [String: String]
    }

    /// Edition ID of the multi-edition ISO, the release name ("26H2") and the hash table
    /// ("<tr><td>Italian 64-bit</td><td>4A15…</td></tr>").
    static func parsePage(_ data: Data) throws -> PageInfo {
        let html = String(decoding: data, as: UTF8.self)
        guard let edition = html.firstMatch(of: #/<option value="([0-9]{1,6})">\s*Windows 11/#) else {
            throw DownloadError.malformedMetadata("no Windows 11 edition on the download page")
        }
        var hashes: [String: String] = [:]
        for m in html.matches(of: #/<tr><td>([^<]{1,80})</td><td>([0-9A-Fa-f]{64})</td></tr>/#) {
            var name = String(m.1).trimmingCharacters(in: .whitespaces)
            for suffix in [" 64-bit", " 32-bit", " Arm64"] where name.hasSuffix(suffix) {
                name = String(name.dropLast(suffix.count))
            }
            hashes[hashKey(name)] = m.2.lowercased()
        }
        guard !hashes.isEmpty else { throw DownloadError.malformedMetadata("no SHA-256 table on the download page") }
        let release = html.firstMatch(of: #/\b(2[0-9]H[12])\b/#).map { String($0.1) }
        return PageInfo(editionID: String(edition.1), release: release, hashes: hashes)
    }

    /// The hash table and the API name some languages differently ("Chinese Simplified" /
    /// "Chinese (Simplified)", "English International" / "English (United Kingdom)").
    static func hashKey(_ language: String) -> String {
        let k = language.lowercased().filter { $0 != "(" && $0 != ")" }
        return k == "english united kingdom" ? "english international" : k
    }

    /// The `w` and `rticks` values that the ov-df script would send back.
    static func parseMdt(_ data: Data) throws -> (w: String, rticks: String) {
        let js = String(decoding: data, as: UTF8.self)
        guard let w = js.firstMatch(of: #/[?&]w=([A-F0-9]{1,64})/#),
              let r = js.firstMatch(of: #/rticks="\+?([0-9]{1,20})/#)
        else { throw DownloadError.malformedMetadata("ov-df script") }
        return (String(w.1), String(r.1))
    }

    private struct APIError: Decodable {
        let key: String?
        let type: Int?
        let value: String?
        enum CodingKeys: String, CodingKey {
            case key = "Key"
            case type = "Type"
            case value = "Value"
        }
    }

    private struct Validation: Decodable {
        let Errors: [APIError]?
    }

    /// Microsoft's anti-automation filter ("Sentinel", types 8 and 9) shows users error
    /// 715-123130 on its page; it lifts after a while.
    private static func checkErrors(_ errors: [APIError]?) throws {
        guard let e = errors?.first else { return }
        let sentinel = e.type == 9 || e.type == 8 || (e.key ?? "").contains("Sentinel")
        throw DownloadError.refused(sentinel ? "715-123130" : (e.value ?? "error"))
    }

    static func parseSkus(_ data: Data) throws -> [WindowsLanguage] {
        struct Sku: Decodable {
            let Id: String
            let Language: String
            let LocalizedLanguage: String?
        }
        struct Reply: Decodable {
            let Skus: [Sku]?
            let Errors: [APIError]?
            let ValidationContainer: Validation?
        }
        guard let r = try? JSONDecoder().decode(Reply.self, from: data) else {
            throw DownloadError.malformedMetadata("SKU list")
        }
        try checkErrors(r.Errors)
        try checkErrors(r.ValidationContainer?.Errors)
        let langs = (r.Skus ?? []).filter { $0.Id.allSatisfy(\.isNumber) && !$0.Id.isEmpty }
            .map { WindowsLanguage(name: $0.Language, localizedName: $0.LocalizedLanguage ?? $0.Language, skuID: $0.Id) }
        guard !langs.isEmpty else { throw DownloadError.malformedMetadata("no languages") }
        return langs
    }

    static func parseLinks(_ data: Data) throws -> (url: URL, displayName: String) {
        struct Option: Decodable {
            let Uri: String
            let ProductDisplayName: String?
            let Name: String?
        }
        struct Reply: Decodable {
            let ProductDownloadOptions: [Option]?
            let Errors: [APIError]?
            let ValidationContainer: Validation?
        }
        guard let r = try? JSONDecoder().decode(Reply.self, from: data) else {
            throw DownloadError.malformedMetadata("download links")
        }
        try checkErrors(r.Errors)
        try checkErrors(r.ValidationContainer?.Errors)
        // Only an ISO served over HTTPS by Microsoft is accepted.
        for o in r.ProductDownloadOptions ?? [] {
            guard let url = URL(string: o.Uri), url.scheme == "https",
                  let host = url.host?.lowercased(), host == "microsoft.com" || host.hasSuffix(".microsoft.com"),
                  url.pathExtension.lowercased() == "iso"
            else { continue }
            return (url, o.ProductDisplayName ?? o.Name ?? "Windows 11")
        }
        throw DownloadError.notFound("Windows ISO link")
    }

    /// Microsoft's name for the language of `locale`, if offered; else UK English.
    public static func defaultLanguage(_ locale: Locale, available: [WindowsLanguage]) -> String {
        let code = locale.language.languageCode?.identifier ?? "en"
        let region = locale.region?.identifier
        let script = locale.language.script?.identifier
        let name: String
        switch (code, region) {
        case ("en", "US"): name = "English"
        case ("en", _): name = "English (United Kingdom)"
        case ("pt", "BR"): name = "Brazilian Portuguese"
        case ("es", "MX"): name = "Spanish (Mexico)"
        case ("fr", "CA"): name = "French Canadian"
        case ("zh", "TW"), ("zh", "HK"), ("zh", "MO"): name = "Chinese (Traditional)"
        case ("zh", _): name = script == "Hant" ? "Chinese (Traditional)" : "Chinese (Simplified)"
        case ("sr", _): name = "Serbian Latin"
        case ("nb", _), ("nn", _), ("no", _): name = "Norwegian"
        default: name = Locale(identifier: "en_US").localizedString(forLanguageCode: code) ?? "English (United Kingdom)"
        }
        let names = Set(available.map(\.name))
        if names.contains(name) { return name }
        if names.contains("English (United Kingdom)") { return "English (United Kingdom)" }
        return available.first?.name ?? name
    }
}
