import Foundation
@testable import IrufusCore

// SHA256SUMS and SHA256SUMS.gpg of https://releases.ubuntu.com/resolute/, October 2026.
let ubuntuSums = Data("""
487f87faaf547ea30e0aba4d5b53346292571256b25333a978db1692bcee9dd2 *ubuntu-26.04-desktop-amd64.iso
dec49008a71f6098d0bcfc822021f4d042d5f2db279e4d75bdd981304f1ca5d9 *ubuntu-26.04-live-server-amd64.iso
96c7f5fb28a7fe28245331f9bfbe4375f18dd29a4850116ad3c4f60f6700c55c *ubuntu-26.04-wsl-amd64.wsl
601e30fbf5d97759367c632e2c33630665039b7e2158fd068403da3ccf1bda1f *ubuntu-26.04.1-desktop-amd64.iso
cc8a95cde20f6ced61a322420de00f10cc3c90ced545daa46cb9c1a117f1d927 *ubuntu-26.04.1-live-server-amd64.iso
48d56724b5c8e60f24893e83e73bbb58c60b3ca22fba3da977075420acd54104 *ubuntu-26.04.1-wsl-amd64.wsl

""".utf8)

let ubuntuSumsSignature = Data("""
-----BEGIN PGP SIGNATURE-----

iQIzBAABCgAdFiEEhDk43yKNIvezdCvA2Uqj8O/iEJIFAmqQvX0ACgkQ2Uqj8O/i
EJIkYRAAlB7NEEc/kHa3pcWQOxR66++U09Jaf4UTvFHEasVjQo/45teZLZv4W/nJ
k/NxzSPAv/Do6IYp4Vd4430sT8uk3z2W/V7QO/TMolGcgmNY8IYbo2QZ7M1snSz5
I0ANN1lHr24EnuzoWJtpMO50ngPGUph8ZpcGP3r7jfjFANQ5HXIPEdqeQ8skfoKf
r2S8yKa5Y7uup1fXHNgVdXCp1mbZJ09BhM8FpksSafeCsHOT1Dztvoon1DhmD8HP
NSaGCY/39IxbK4P2EbdGlrCXPXZiPA7C6zshwQ4uESIcMYQj0tYl48BKApSb6Vrd
5wEE33mq33FazOewpHMLiYByBFT8BIqDlJqwP3BFxdcX3lj5noQFZOmjL8OmTpL/
3h/thQdOo2fvGlv/bztuL8rKgjPdjGQb1gTjPTix1Tg5+gMBfUKv4m4oF3THittR
MWQWYpr5RZJxt7ayBTakTyeLywQtAXQXVunO3pkTNtKK2GOKdXEKif8PqaZ1Dwu2
2IzXwpTXTUvbf3/BpFIlcgkYiKCwk1AsPrri/HZy5Wguw9j06EJRwt8rR6zvYpy/
r+n46KH3o59Au+WAO+Zd5Rgcvj0LW6kMD84AVuPhwqe5tr/njfqSUXCfFT1riH40
weoCeT1g1CYtziK8WgTmxUIGW9mIhq9MUkmo8jKoUtN3PADI/G4=
=SSQP
-----END PGP SIGNATURE-----

""".utf8)

// The same list signed by Kali's archive key (2025), which iRufus does not trust for Ubuntu.
let kaliSignature = Data("""
-----BEGIN PGP SIGNATURE-----

iQIzBAABCgAdFiEEgnyFafJRjMZ3/soa7WVGLsjV5MUFAmo7X4QACgkQ7WVGLsjV
5MWZ6g//YsxLC/SY1335cpRNvdW+NNd9w2x0rZHdW+qxY9rbrFCKF4zz48JGIoWc
dIRk9H5Z/H9Kcg+TMRfXjdiExHAAZNIfhXQHEnyDeev/R3rxwMZXOZrri53cL/YV
g+ObE0V/Ya/EXS1EyT1gkYNEfo0TNBzYSywV2wrXVVNpXbF0z1yNfn/pRq12r3R6
Mf7J3DKeNgIv775PCNDcFqcMq+8DrZf+y8Yxg7WHtD8zWn27hCNUjRgK5UeNu28M
iS3J1kSHlfsApFk1WzbqobTCxksPfg6PWGt4yNfm0HzHTU0fp7QlBcmGJVxouOuR
+xHxw5A+tnusMA+CKFBo/nMHiLC3ZHxUo/TVL8AFShZs8HoSEz6NbwlffgmKiTQm
D8i/wG7f+d84jcFuPEPCJXb03xqs2Lh6LuzM6CQ89M5RSmHNZoRmp8PY4bSqjE7u
CjXlMJBW/TI+U6JGJmU5j9Jw9mJnGa6Y0txh5qb5YL0Rc+Tzqrn7rCj/h51DALdB
iQyoWCvKqnGoEE3OjH9yrGGGUuYo8+XeRGdUgqz/kRlMKDJCmyOhPRmL4G2qMYkI
Oxbp4NfdB7ucxOnDyeQUNNiyH8IHlWJ2P+Tuc0zBIblig2xRCgPDyScS3MJMfxzQ
zlhBFRJrLbFq5W1RYjAAEK1DjvAeptp8ft8zM7AUXOj1+TO6gLc=
=PKna
-----END PGP SIGNATURE-----

""".utf8)

// systemrescue-13.02-amd64.iso.asc (signed by the SystemRescue subkey 6298 9046 …).
let systemRescueSignature = Data("""
-----BEGIN PGP SIGNATURE-----

iQIzBAABCgAdFiEEYpiQRutcfphezfXdOw/qm+E8o8kFAmptlAEACgkQOw/qm+E8
o8kfwhAAl0cHPSU/n263wfcIthUX3nzn28lCfqfWjsTAC4EgHnRQyoAKImpC5c1F
wSjjZEN4rSNhZqfxJoEKP5BJJbYONQIi3DF2IRoWWtae76vy1YmgwyeHyhYM5z/3
5xuloC/YOwH94456sMPcivheHmA87dqiiefCsPTUYMADnAV0pd8vFNZnotyukZJq
LTyn5S7rPB3DknGBrPUDHgS8vrbCf3nj09mB7WVo1IgVJKyXgLbu728KlkPNtVfd
l9yikLsYT6KH9atIrVLNwz5VDYB+JfersVzOxroqlf4P39ZInHTpX8HK9qttds8A
5zEuf1E07OXbWsw5NK/dsggQ46Yi5Qe5EE0sXDVR7hoVdR4hxAkfL9irwUBq/SfB
OqjJmYMBn2sVlXj4pcuZMDRWu0DQHP3sbZWiSF15OnB09kaQUXzqc9EJ4B89KUsc
aewOjL8EtYaJyI4V0NlJI+h2Wt1ZUtn12llWXSZtSTA4Lj64Q6dICZVlXT73k9Yz
LynOxTcJHIhsiS+vJTcIbT1tqMrkXRAVPpoXAXXFmCKCc1NAJAI3/4+LJCAEbDNu
WMXzco/+EgqpcTX9fBXj0iEx5Gvr35vgVtTIZuEgKUEPqVggh5OcwhsWuGbUFX+F
vlW4SvLMKTj8jSwA/OicJ1bC9IYjom4aERIFHGf2x6VsBekegBw=
=+0yF
-----END PGP SIGNATURE-----
""".utf8)

let systemRescuePage = Data("""
<a href="https://fastly-cdn.system-rescue.org/releases/13.02/systemrescue-13.02-amd64.iso">Fastly</a>
<a href="/releases/13.02/systemrescue-13.02-amd64.iso.sha256">sha256</a>
<a href="/releases/12.01/systemrescue-12.01-amd64.iso">old</a>
<a href="/releases/13.02/systemrescue-13.02-amd64.iso.asc">asc</a>
""".utf8)

let ubuntuMetaRelease = Data("""
Dist: jammy
Name: Jammy Jellyfish
Version: 22.04.5 LTS
Supported: 1

Dist: noble
Name: Noble Numbat
Version: 24.04.5 LTS
Supported: 1

Dist: resolute
Name: Resolute Raccoon
Version: 26.04.1 LTS
Supported: 1

Dist: zesty
Version: 99.04 LTS
Supported: 0

""".utf8)

struct DownloadTests {
    func pinnedKeysMatchTheirFingerprints() throws {
        let k = DownloadCatalog.ubuntuKey
        expect(try k.computedFingerprint() == k.fingerprint)
        let sr = DownloadCatalog.systemRescueKey
        expect(try sr.computedFingerprint() == sr.fingerprint)
        expect(try sr.secKey().modulusBytes == 512)
        expect(k.formattedFingerprint == "8439 38DF 228D 22F7 B374 2BC0 D94A A3F0 EFE2 1092")
        let forged = OpenPGPKey(name: "x", fingerprint: "843938DF228D22F7B3742BC0D94AA3F0EFE21092",
                                packet: Data(Data(base64Encoded: k.packet)!.dropLast()).base64EncodedString())
        expectThrows(OpenPGPError.self) { _ = try forged.secKey() }
    }

    func realUbuntuSignatureVerifies() throws {
        let key = try OpenPGP.verify(detachedSignature: ubuntuSumsSignature, of: ubuntuSums, keys: [DownloadCatalog.ubuntuKey])
        expect(key.fingerprint == DownloadCatalog.ubuntuKey.fingerprint)
        // Binary (dearmored) form.
        let binary = try OpenPGP.dearmor(ubuntuSumsSignature)
        expect(binary.first == 0x89)
        _ = try OpenPGP.verify(detachedSignature: binary, of: ubuntuSums, keys: [DownloadCatalog.ubuntuKey])
        // Streaming verification of a file gives the same result.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("irufus-sums-\(UUID().uuidString)")
        try ubuntuSums.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        _ = try OpenPGP.verify(detachedSignature: ubuntuSumsSignature, ofFile: url, keys: [DownloadCatalog.ubuntuKey])
        try (ubuntuSums + Data([0x0A])).write(to: url)
        expect(throwsError(.badSignature) { try OpenPGP.verify(detachedSignature: ubuntuSumsSignature, ofFile: url, keys: [DownloadCatalog.ubuntuKey]) })
        // The SystemRescue signature names the pinned subkey (the image itself is too large for a check).
        let sig = try OpenPGP.parseSignature(try OpenPGP.dearmor(systemRescueSignature))
        expect(sig.issuers.contains(DownloadCatalog.systemRescueKey.fingerprint))
        expect(throwsError(.badSignature) { try OpenPGP.verify(detachedSignature: systemRescueSignature, of: ubuntuSums, keys: [DownloadCatalog.systemRescueKey]) })
    }

    func tamperedOrForeignSignaturesAreRejected() {
        var tampered = ubuntuSums
        tampered[0] = UInt8(ascii: "5")
        expect(throwsError(.badSignature) { try OpenPGP.verify(detachedSignature: ubuntuSumsSignature, of: tampered, keys: [DownloadCatalog.ubuntuKey]) })
        expect(throwsError(.unknownKey) { try OpenPGP.verify(detachedSignature: kaliSignature, of: ubuntuSums, keys: [DownloadCatalog.ubuntuKey]) })
        expect(throwsError(.unknownKey) { try OpenPGP.verify(detachedSignature: ubuntuSumsSignature, of: ubuntuSums, keys: []) })
        // Flip one bit of the RSA value (last byte before the armor checksum).
        var binary = (try? OpenPGP.dearmor(ubuntuSumsSignature)) ?? Data()
        binary[binary.count - 1] ^= 1
        expect(throwsError(.badSignature) { try OpenPGP.verify(detachedSignature: binary, of: ubuntuSums, keys: [DownloadCatalog.ubuntuKey]) })
        expectThrows(OpenPGPError.self) { try OpenPGP.verify(detachedSignature: Data("garbage".utf8), of: ubuntuSums, keys: [DownloadCatalog.ubuntuKey]) }
        expectThrows(OpenPGPError.self) { try OpenPGP.verify(detachedSignature: binary.prefix(40), of: ubuntuSums, keys: [DownloadCatalog.ubuntuKey]) }
    }

    func ubuntuMetadataIsParsed() throws {
        expect(try DownloadCatalog.latestUbuntuLTS(ubuntuMetaRelease) == "resolute")
        expectThrows(DownloadError.self) { _ = try DownloadCatalog.latestUbuntuLTS(Data("Dist: ../x\nVersion: 30.04 LTS\nSupported: 1\n".utf8)) }
        let sums = try DownloadCatalog.parseChecksums(ubuntuSums)
        expect(sums.count == 6)
        let latest = try DownloadCatalog.latestUbuntuDesktop(sums)
        expect(latest.file == "ubuntu-26.04.1-desktop-amd64.iso")
        expect(latest.version == "26.04.1")
        expect(latest.sha256 == "601e30fbf5d97759367c632e2c33630665039b7e2158fd068403da3ccf1bda1f")
        // Names that could escape the download folder are dropped.
        let evil = try DownloadCatalog.parseChecksums(Data("\(String(repeating: "a", count: 64)) *../ubuntu-99.04-desktop-amd64.iso\n\(String(repeating: "b", count: 64))  ok.iso\n".utf8))
        expect(evil.keys.sorted() == ["ok.iso"])
    }

    func systemRescueMetadataIsParsed() throws {
        expect(try DownloadCatalog.latestSystemRescue(systemRescuePage) == "13.02")
        let newer = Data(String(decoding: systemRescuePage, as: UTF8.self).appending("systemrescue-13.10-amd64.iso").utf8)
        expect(try DownloadCatalog.latestSystemRescue(newer) == "13.10")
        // Releases older than the minimum are never offered.
        expectThrows(DownloadError.self) { _ = try DownloadCatalog.latestSystemRescue(Data("systemrescue-12.01-amd64.iso".utf8)) }
    }

    func resolutionUsesOnlyVerifiedMetadata() async throws {
        let files: [String: Data] = [
            "https://changelogs.ubuntu.com/meta-release-lts": ubuntuMetaRelease,
            "https://releases.ubuntu.com/resolute/SHA256SUMS": ubuntuSums,
            "https://releases.ubuntu.com/resolute/SHA256SUMS.gpg": ubuntuSumsSignature,
        ]
        let d = try await DownloadCatalog.resolve(.ubuntuDesktop) { url in
            guard let data = files[url.url!.absoluteString] else { throw DownloadError.network("404 \(url)") }
            return data
        }
        expect(d.url.absoluteString == "https://releases.ubuntu.com/resolute/ubuntu-26.04.1-desktop-amd64.iso")
        expect(d.verification == .signedChecksums(keyName: DownloadCatalog.ubuntuKey.name, fingerprint: DownloadCatalog.ubuntuKey.fingerprint))

        var tampered = files
        tampered["https://releases.ubuntu.com/resolute/SHA256SUMS"] = Data(String(decoding: ubuntuSums, as: UTF8.self).replacingOccurrences(of: "601e", with: "701e").utf8)
        do {
            _ = try await DownloadCatalog.resolve(.ubuntuDesktop) { tampered[$0.url!.absoluteString]! }
            fail("a tampered checksum list was accepted")
        } catch DownloadError.signature(.badSignature) {
        } catch {
            fail("unexpected \(error)")
        }

        let sr: [String: Data] = [
            "https://www.system-rescue.org/Download/": systemRescuePage,
            "https://www.system-rescue.org/releases/13.02/systemrescue-13.02-amd64.iso.sha256":
                Data("ad4d670b72859d887c7960142a9a9d36a3e50446694a035e254442f65d6e7572 *systemrescue-13.02-amd64.iso\n".utf8),
            "https://www.system-rescue.org/releases/13.02/systemrescue-13.02-amd64.iso.asc": systemRescueSignature,
        ]
        let r = try await DownloadCatalog.resolve(.systemRescue) { url in
            guard let data = sr[url.url!.absoluteString] else { throw DownloadError.network("404 \(url)") }
            return data
        }
        expect(r.url.absoluteString == "https://fastly-cdn.system-rescue.org/releases/13.02/systemrescue-13.02-amd64.iso")
        expect(r.url.host == DownloadProduct.systemRescue.publisherHost)
        expect(r.sha256 == "ad4d670b72859d887c7960142a9a9d36a3e50446694a035e254442f65d6e7572")
        expect(r.imageSignature == systemRescueSignature)
        expect(r.verification == .signedImage(keyName: DownloadCatalog.systemRescueKey.name, fingerprint: DownloadCatalog.systemRescueKey.fingerprint))
        // A signature by another key is refused before anything is downloaded.
        var foreign = sr
        foreign["https://www.system-rescue.org/releases/13.02/systemrescue-13.02-amd64.iso.asc"] = ubuntuSumsSignature
        do {
            _ = try await DownloadCatalog.resolve(.systemRescue) { foreign[$0.url!.absoluteString]! }
            fail("a signature by another key was accepted")
        } catch DownloadError.signature(.unknownKey) {
        } catch {
            fail("unexpected \(error)")
        }

        let dos = try await DownloadCatalog.resolve(.freeDOSLite) { _ in throw DownloadError.network("no network needed") }
        expect(dos.url.scheme == "https" && dos.fileName == "FD14-LiteUSB.zip" && dos.verification == .pinnedChecksum)
        for p in DownloadProduct.allCases where p.family == .dos {
            let r = try await DownloadCatalog.resolve(p) { _ in Data() }
            expect(r.sha256.count == 64 && r.url.host == p.publisherHost)
            expect(try DownloadCatalog.destination(for: r, in: URL(fileURLWithPath: "/tmp")).path == "/tmp/\(r.fileName)")
        }
    }

    private func throwsError(_ expected: OpenPGPError, _ body: () throws -> Any) -> Bool {
        do {
            _ = try body()
            return false
        } catch let e as OpenPGPError {
            return e == expected
        } catch {
            return false
        }
    }
}
