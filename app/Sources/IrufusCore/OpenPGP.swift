// iRufus — SPDX-License-Identifier: GPL-3.0-or-later
// Minimal OpenPGP (RFC 4880) verifier for the detached signatures that Linux
// distributions publish next to their checksum lists (SHA256SUMS.gpg). Only what
// (SHA256SUMS.gpg) or next to the image itself (.iso.asc). Only what those
// signatures use is supported: version 4 signatures of binary documents, RSA keys,
// SHA-256/384/512. Keys are pinned in the source as the body of their public-key
// (or public-subkey) packet; the fingerprint is recomputed from it, so a pasted key
// that does not match its declared fingerprint is rejected (and caught by the checks).
// A pinned signing subkey is trusted directly: its binding to the primary key is
// not needed because the pin, not the primary key, is the trust anchor.

import CryptoKit
import Foundation
import Security

public enum OpenPGPError: Error, Equatable, Sendable {
    case malformed(String)
    case unsupported(String)
    case unknownKey
    case expired
    case badSignature
}

public struct OpenPGPKey: Sendable {
    public let name: String
    /// Uppercase hex v4 fingerprint, as published by the distribution.
    public let fingerprint: String
    /// Base64 of the public-key packet body (version, creation time, algorithm, MPIs).
    let packet: String

    public init(name: String, fingerprint: String, packet: String) {
        self.name = name
        self.fingerprint = fingerprint
        self.packet = packet
    }

    /// "8439 38DF 228D …", for display.
    public var formattedFingerprint: String {
        let c = Array(fingerprint)
        return stride(from: 0, to: c.count, by: 4).map { String(c[$0..<min($0 + 4, c.count)]) }.joined(separator: " ")
    }

    /// V4 fingerprint recomputed from the packet: SHA-1(0x99 ‖ length ‖ body).
    func computedFingerprint() throws -> String {
        guard let body = Data(base64Encoded: packet), body.count <= 0xFFFF else { throw OpenPGPError.malformed("key packet") }
        var h = Insecure.SHA1()
        h.update(data: Data([0x99, UInt8(body.count >> 8), UInt8(body.count & 0xFF)]))
        h.update(data: body)
        return h.finalize().map { String(format: "%02X", $0) }.joined()
    }

    /// The RSA public key, after checking the packet against the pinned fingerprint.
    func secKey() throws -> (SecKey, modulusBytes: Int) {
        guard try computedFingerprint() == fingerprint else { throw OpenPGPError.malformed("key fingerprint") }
        var r = ByteReader(Data(base64Encoded: packet)!)
        guard try r.byte() == 4 else { throw OpenPGPError.unsupported("key version") }
        _ = try r.bytes(4)
        guard try r.byte() == 1 else { throw OpenPGPError.unsupported("key algorithm") }
        let n = try r.mpi(), e = try r.mpi()
        let der = DER.sequence(DER.integer(n) + DER.integer(e))
        let attrs: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic]
        guard let key = SecKeyCreateWithData(der as CFData, attrs as CFDictionary, nil) else {
            throw OpenPGPError.malformed("RSA key")
        }
        return (key, n.count)
    }
}

public enum OpenPGP {
    /// Verify a detached signature (armored or binary) of `data` made by one of `keys`.
    /// Returns the key that made it.
    @discardableResult
    public static func verify(detachedSignature: Data, of data: Data, keys: [OpenPGPKey], now: Date = Date()) throws -> OpenPGPKey {
        try verify(detachedSignature: detachedSignature, keys: keys, now: now) { update in update(data) }
    }

    /// Same, for a file read in chunks (images of several gigabytes).
    @discardableResult
    public static func verify(detachedSignature: Data, ofFile url: URL, keys: [OpenPGPKey], now: Date = Date()) throws -> OpenPGPKey {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try verify(detachedSignature: detachedSignature, keys: keys, now: now) { update in
            while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
                update(chunk)
            }
        }
    }

    /// `content` feeds the signed document to the hash, in as many pieces as it likes.
    private static func verify(detachedSignature: Data, keys: [OpenPGPKey], now: Date,
                               content: ((Data) -> Void) throws -> Void) throws -> OpenPGPKey {
        let sig = try parseSignature(try dearmor(detachedSignature))
        guard let key = keys.first(where: { sig.issuers.contains($0.fingerprint) || sig.issuerKeyIDs.contains(String($0.fingerprint.suffix(16))) }) else {
            throw OpenPGPError.unknownKey
        }
        if let expiry = sig.expiresAfter, expiry > 0, now.timeIntervalSince1970 > Double(sig.created) + Double(expiry) {
            throw OpenPGPError.expired
        }
        func hash<H: HashFunction>(_: H.Type) throws -> Data {
            var h = H()
            try content { h.update(data: $0) }
            h.update(data: sig.trailer)
            return Data(h.finalize())
        }
        let digest: Data
        let algorithm: SecKeyAlgorithm
        switch sig.hashAlgorithm {
        case 8: digest = try hash(SHA256.self); algorithm = .rsaSignatureDigestPKCS1v15SHA256
        case 9: digest = try hash(SHA384.self); algorithm = .rsaSignatureDigestPKCS1v15SHA384
        case 10: digest = try hash(SHA512.self); algorithm = .rsaSignatureDigestPKCS1v15SHA512
        default: throw OpenPGPError.unsupported("hash algorithm \(sig.hashAlgorithm)")
        }
        guard digest.prefix(2) == sig.hashPrefix else { throw OpenPGPError.badSignature }
        let (secKey, modulusBytes) = try key.secKey()
        guard sig.value.count <= modulusBytes else { throw OpenPGPError.badSignature }
        let value = Data(repeating: 0, count: modulusBytes - sig.value.count) + sig.value
        guard SecKeyVerifySignature(secKey, algorithm, digest as CFData, value as CFData, nil) else {
            throw OpenPGPError.badSignature
        }
        return key
    }

    struct Signature {
        var hashAlgorithm: UInt8 = 0
        var created: UInt32 = 0
        var expiresAfter: UInt32?
        var issuers: Set<String> = []
        var issuerKeyIDs: Set<String> = []
        /// Hashed part of the packet followed by the v4 trailer.
        var trailer = Data()
        var hashPrefix = Data()
        var value = Data()
    }

    /// ASCII armor → binary; binary input is returned unchanged.
    static func dearmor(_ input: Data) throws -> Data {
        guard let text = String(data: input, encoding: .utf8), text.hasPrefix("-----BEGIN PGP SIGNATURE-----") else {
            return input
        }
        var lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.dropFirst()
        // Armor headers ("Version: …") end at the first empty line.
        while let l = lines.first, !l.isEmpty { lines.removeFirst() }
        var b64 = ""
        for l in lines {
            if l.hasPrefix("=") || l.hasPrefix("-----") { break }
            b64 += l
        }
        guard let data = Data(base64Encoded: b64), !data.isEmpty else { throw OpenPGPError.malformed("armor") }
        return data
    }

    static func parseSignature(_ packet: Data) throws -> Signature {
        var r = ByteReader(packet)
        let header = try r.byte()
        guard header & 0x80 != 0 else { throw OpenPGPError.malformed("packet header") }
        let tag: UInt8
        let length: Int
        if header & 0x40 != 0 {
            tag = header & 0x3F
            let l0 = Int(try r.byte())
            switch l0 {
            case ..<192: length = l0
            case 192..<224: length = ((l0 - 192) << 8) + Int(try r.byte()) + 192
            case 255: length = Int(try r.uint32())
            default: throw OpenPGPError.unsupported("partial body length")
            }
        } else {
            tag = (header >> 2) & 0x0F
            switch header & 3 {
            case 0: length = Int(try r.byte())
            case 1: length = Int(try r.uint16())
            case 2: length = Int(try r.uint32())
            default: throw OpenPGPError.unsupported("indeterminate length")
            }
        }
        guard tag == 2 else { throw OpenPGPError.malformed("not a signature packet") }
        var b = ByteReader(try r.bytes(length))

        var sig = Signature()
        guard try b.byte() == 4 else { throw OpenPGPError.unsupported("signature version") }
        // 0x00: signature of a binary document (text signatures need canonical line endings).
        guard try b.byte() == 0x00 else { throw OpenPGPError.unsupported("signature type") }
        guard try b.byte() == 1 else { throw OpenPGPError.unsupported("public-key algorithm") }
        sig.hashAlgorithm = try b.byte()
        let hashedLength = Int(try b.uint16())
        try parseSubpackets(try b.bytes(hashedLength), hashed: true, into: &sig)
        let hashedEnd = b.offset
        try parseSubpackets(try b.bytes(Int(try b.uint16())), hashed: false, into: &sig)
        sig.hashPrefix = try b.bytes(2)
        sig.value = try b.mpi()
        guard b.isAtEnd else { throw OpenPGPError.malformed("trailing data") }
        guard sig.created != 0 else { throw OpenPGPError.malformed("no creation time") }

        let hashed = b.data.prefix(hashedEnd)
        let n = UInt32(hashed.count)
        sig.trailer = hashed + Data([0x04, 0xFF, UInt8(n >> 24), UInt8((n >> 16) & 0xFF), UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)])
        return sig
    }

    private static func parseSubpackets(_ area: Data, hashed: Bool, into sig: inout Signature) throws {
        var r = ByteReader(area)
        while !r.isAtEnd {
            let l0 = Int(try r.byte())
            let length: Int
            switch l0 {
            case ..<192: length = l0
            case 192..<255: length = ((l0 - 192) << 8) + Int(try r.byte()) + 192
            default: length = Int(try r.uint32())
            }
            guard length >= 1 else { throw OpenPGPError.malformed("subpacket") }
            var s = ByteReader(try r.bytes(length))
            let type = try s.byte()
            let critical = type & 0x80 != 0
            switch type & 0x7F {
            case 2 where hashed: sig.created = try s.uint32()
            case 3 where hashed: sig.expiresAfter = try s.uint32()
            case 16: sig.issuerKeyIDs.insert(hex(try s.bytes(8)))
            case 33:
                guard try s.byte() == 4 else { break }
                sig.issuers.insert(hex(try s.bytes(20)))
            default:
                // RFC 4880 §5.2.3.1: an unknown critical subpacket invalidates the signature.
                if critical && hashed { throw OpenPGPError.unsupported("critical subpacket \(type & 0x7F)") }
            }
        }
    }

    static func hex(_ d: Data) -> String { d.map { String(format: "%02X", $0) }.joined() }
}

struct ByteReader {
    let data: Data
    private(set) var offset = 0

    init(_ data: Data) { self.data = Data(data) }

    var isAtEnd: Bool { offset == data.count }

    mutating func bytes(_ n: Int) throws -> Data {
        guard n >= 0, n <= data.count - offset else { throw OpenPGPError.malformed("truncated") }
        defer { offset += n }
        return data.subdata(in: offset..<offset + n)
    }

    mutating func byte() throws -> UInt8 { try bytes(1)[0] }
    mutating func uint16() throws -> UInt16 { try bytes(2).reduce(0) { $0 << 8 | UInt16($1) } }
    mutating func uint32() throws -> UInt32 { try bytes(4).reduce(0) { $0 << 8 | UInt32($1) } }

    /// Multiprecision integer, without leading zero bytes.
    mutating func mpi() throws -> Data {
        let bits = Int(try uint16())
        let v = try bytes((bits + 7) / 8)
        return Data(v.drop(while: { $0 == 0 }))
    }
}

/// Just enough DER to build a PKCS#1 RSAPublicKey for SecKeyCreateWithData.
enum DER {
    static func length(_ n: Int) -> Data {
        if n < 0x80 { return Data([UInt8(n)]) }
        var bytes: [UInt8] = []
        var v = n
        while v > 0 { bytes.insert(UInt8(v & 0xFF), at: 0); v >>= 8 }
        return Data([0x80 | UInt8(bytes.count)] + bytes)
    }

    static func integer(_ magnitude: Data) -> Data {
        var v = magnitude.isEmpty ? Data([0]) : magnitude
        if v.first! & 0x80 != 0 { v.insert(0, at: 0) }
        return Data([0x02]) + length(v.count) + v
    }

    static func sequence(_ content: Data) -> Data { Data([0x30]) + length(content.count) + content }
}
