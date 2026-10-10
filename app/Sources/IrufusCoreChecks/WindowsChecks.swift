import Foundation
@testable import IrufusCore

// Excerpts of the real replies (October 2026, Windows 11 26H2), from
// https://www.microsoft.com/en-us/software-download/windows11 and its download API.
let windowsPage = Data("""
<h2>Download Windows 11 Disk Image (ISO) for x64 devices</h2><p>Windows 11 2026 Update l Version 26H2</p>
<select id="product-edition" aria-label="Select Windows 11 ISOs for X64 "><option value="" selected="selected">Select Download</option>
<option value="3813">Windows 11 (multi-edition ISO for x64 devices)</option></select>
<table><tr><td>German 64-bit</td><td>193BBDE65EC84E298A1C798959489C8375ED501CF973C6D37FA52BB22EE8D43B</td></tr>
<tr><td>English International 64-bit</td><td>7E3F373BD3C2321B5D5125DFCF718DFBF1A0ABC50A267118669951890DF98A5D</td></tr>
<tr><td>English 64-bit</td><td>BD4307DF32BC8AF33B39CCECB1174AEB345386630F89A2B86C7A4E36B55EA650</td></tr>
<tr><td>Italian 64-bit</td><td>4A155CFF6748F433B017761FF0B5B6029878EC6EF267674418D65E0FED7D0520</td></tr></table>
""".utf8)

let windowsMdt = Data(#"""
function SendBack(url,callback){callback(url)}window.dfp={url:"https://ov-df.microsoft.com/?session_id=c9cca959-77aa-436a-b9a1-594e71c8040a&CustomerId=560dc9f3-1aa5-4a2f-b63c-9e18f8d0e175&PageId=si&w=8DF26E07265FC0D",sessionId:"c9cca959-77aa-436a-b9a1-594e71c8040a",customerId:"560dc9f3-1aa5-4a2f-b63c-9e18f8d0e175",dc:"westeurope"};window.dfp.doFpt=function(doc){var start,frm,src;if(true){start=Date.now();frm=doc.createElement("IFRAME");frm.id="fpt_frame";frm.setAttribute("style","color:#000000;float:left;visibility:hidden;position:absolute;width:100px;height:100px;left:-200px;top:-200px;border:0px");src="https://ov-df.microsoft.com/?session_id=c9cca959-77aa-436a-b9a1-594e71c8040a&CustomerId=560dc9f3-1aa5-4a2f-b63c-9e18f8d0e175&PageId=si&w=8DF26E07265FC0D";src+="&mdt="+start;src+="&rticks="+1791644954371;false&&(src+="&lhp="+encodeURIComponent(location.pathname.substring(0,255)));function SetIFrameSrc(url){frm.setAttribute("src",url);doc.body.appendChild(frm)}SendBack(src,SetIFrameSrc)}};
"""#.utf8)

let windowsSkus = Data(#"""
{"ValidationContainer":{"Errors":[]},"Skus":[{"Id":"27157","Language":"Chinese (Simplified)","LocalizedProductDisplayName":"Windows 11 Client - Build 26300.9457 Chinese (Simplified)","LocalizedLanguage":"Chinese Simplified","ProductDisplayName":"Windows 11 Client - Build 26300.9457"},{"Id":"27160","Language":"English","LocalizedProductDisplayName":"Windows 11 Client - Build 26300.9457 English","LocalizedLanguage":"English (United States)","ProductDisplayName":"Windows 11 Client - Build 26300.9457"},{"Id":"27128","Language":"English (United Kingdom)","LocalizedProductDisplayName":"Windows 11 Client - Build 26300.9457 English (United Kingdom)","LocalizedLanguage":"English International","ProductDisplayName":"Windows 11 Client - Build 26300.9457"},{"Id":"27126","Language":"German","LocalizedProductDisplayName":"Windows 11 Client - Build 26300.9457 German","LocalizedLanguage":"German","ProductDisplayName":"Windows 11 Client - Build 26300.9457"},{"Id":"27138","Language":"Italian","LocalizedProductDisplayName":"Windows 11 Client - Build 26300.9457 Italian","LocalizedLanguage":"Italian","ProductDisplayName":"Windows 11 Client - Build 26300.9457"}]}
"""#.utf8)

let windowsLinks = Data(#"""
{"ProductDownloadOptions":[{"Name":"Windows 11 Client - Build 26300.9457 Italian","Uri":"https://software.download.prss.microsoft.com/dbazure/Windows11_Client_x64_it-it_26300_9457.iso?t=00000000-0000-0000-0000-000000000000&P1=1&P2=602&P3=2&P4=AAAA","ProductDisplayName":"Windows 11 Client - Build 26300.9457","Language":"Italian","LocalizedProductDisplayName":"Windows 11 Client - Build 26300.9457 Italian","LocalizedLanguage":"Italian","DownloadType":1}],"ProductDownload":null,"ValidationContainer":{"ErrorList":[],"Errors":[]},"DownloadExpirationDatetime":"2026-10-11T15:09:20.3524039Z"}
"""#.utf8)

let windowsRefused = Data(#"""
{"ValidationContainer":{"Errors":[{"Key":"ErrorSettings.SentinelReject","Value":"Sentinel marked this request as rejected.","Type":9}]},"Skus":[]}
"""#.utf8)


struct WindowsDownloadTests {
    func pageAndProtocolRepliesAreParsed() throws {
        let page = try WindowsDownload.parsePage(windowsPage)
        expect(page.editionID == "3813")
        expect(page.release == "26H2")
        expect(page.hashes["italian"] == "4a155cff6748f433b017761ff0b5b6029878ec6ef267674418d65e0fed7d0520")
        // "English (United Kingdom)" in the API is "English International" in the hash table.
        expect(page.hashes[WindowsDownload.hashKey("English (United Kingdom)")]?.hasPrefix("7e3f373b") == true)
        expectThrows(DownloadError.self) { _ = try WindowsDownload.parsePage(Data("<html>nothing</html>".utf8)) }

        let mdt = try WindowsDownload.parseMdt(windowsMdt)
        expect(mdt.w == "8DF26E07265FC0D" && mdt.rticks == "1791644954371")

        let langs = try WindowsDownload.parseSkus(windowsSkus)
        expect(langs.first { $0.name == "Italian" }?.skuID == "27138")
        expect(langs.first { $0.name == "English" }?.localizedName == "English (United States)")

        let link = try WindowsDownload.parseLinks(windowsLinks)
        expect(link.url.lastPathComponent == "Windows11_Client_x64_it-it_26300_9457.iso")
        expect(link.displayName == "Windows 11 Client - Build 26300.9457")
    }

    func refusalsAndForeignLinksAreRejected() {
        do {
            _ = try WindowsDownload.parseSkus(windowsRefused)
            fail("a refused session was accepted")
        } catch DownloadError.refused(let code) {
            expect(code == "715-123130")
        } catch {
            fail("unexpected \(error)")
        }
        let type8 = Data(#"{"ValidationContainer":{"Errors":[{"Key":"ErrorSettings.SentinelReject","Value":"Sentinel marked this request as rejected.","Type":8}]}}"#.utf8)
        do {
            _ = try WindowsDownload.parseLinks(type8)
            fail("a refused link request was accepted")
        } catch DownloadError.refused(let code) {
            expect(code == "715-123130")
        } catch {
            fail("unexpected \(error)")
        }
        for uri in ["http://software.download.prss.microsoft.com/x.iso",
                    "https://microsoft.com.example.net/x.iso",
                    "https://example.com/Windows11.iso",
                    "https://software.download.prss.microsoft.com/setup.exe"] {
            let json = Data(#"{"ProductDownloadOptions":[{"Uri":"\#(uri)"}]}"#.utf8)
            expectThrows(DownloadError.self) { _ = try WindowsDownload.parseLinks(json) }
        }
    }

    func defaultLanguageFollowsTheSystem() throws {
        let langs = try WindowsDownload.parseSkus(windowsSkus)
        expect(WindowsDownload.defaultLanguage(Locale(identifier: "it_IT"), available: langs) == "Italian")
        expect(WindowsDownload.defaultLanguage(Locale(identifier: "en_US"), available: langs) == "English")
        expect(WindowsDownload.defaultLanguage(Locale(identifier: "en_GB"), available: langs) == "English (United Kingdom)")
        expect(WindowsDownload.defaultLanguage(Locale(identifier: "zh_CN"), available: langs) == "Chinese (Simplified)")
        expect(WindowsDownload.defaultLanguage(Locale(identifier: "fi_FI"), available: langs) == "English (United Kingdom)")
    }

    func resolutionFollowsTheProtocol() async throws {
        let referer = Referer()
        func fake(_ req: URLRequest) async throws -> Data {
            let u = req.url!.absoluteString
            if u == "https://www.microsoft.com/en-us/software-download/windows11" { return windowsPage }
            if u.hasPrefix("https://vlscppe.microsoft.com/tags?org_id=y6jn8c31&session_id=") { return Data() }
            if u.hasPrefix("https://ov-df.microsoft.com/mdt.js?") { return windowsMdt }
            if u.hasPrefix("https://ov-df.microsoft.com/?") {
                guard u.contains("w=8DF26E07265FC0D"), u.contains("rticks=1791644954371") else { throw DownloadError.network("ov-df") }
                return Data()
            }
            if u.contains("/getskuinformationbyproductedition?"), u.contains("productEditionId=3813") { return windowsSkus }
            if u.contains("/GetProductDownloadLinksBySku?"), u.contains("SKU=27138") {
                referer.value = req.value(forHTTPHeaderField: "Referer")
                return windowsLinks
            }
            throw DownloadError.network("unexpected \(u)")
        }
        let d = try await DownloadCatalog.resolve(.windows11, language: "Italian", fetch: fake)
        expect(d.fileName == "Windows11_Client_x64_it-it_26300_9457.iso")
        expect(d.sha256 == "4a155cff6748f433b017761ff0b5b6029878ec6ef267674418d65e0fed7d0520")
        expect(d.version == "26H2 — build 26300.9457")
        expect(d.language == "Italian" && d.languages.count == 5)
        expect(d.verification == .publishedChecksum(page: WindowsDownload.pageURL(.windows11)))
        expect(referer.value == "https://www.microsoft.com/en-us/software-download/windows11")
        expect(try DownloadCatalog.destination(for: d, in: URL(fileURLWithPath: "/tmp")).lastPathComponent == d.fileName)

        // A language without a published SHA-256 is never downloaded.
        do {
            _ = try await DownloadCatalog.resolve(.windows11, language: "Chinese (Simplified)", fetch: fake)
            fail("a language without a published checksum was accepted")
        } catch DownloadError.notFound {
        } catch {
            fail("unexpected \(error)")
        }
    }
}

final class Referer: @unchecked Sendable {
    var value: String?
}
