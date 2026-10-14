import Foundation
import Testing
@testable import DoveKit

struct HostListTests {
    private let list = HostList(hosts: [
        .init(name: "1Fichier", domains: ["1fichier.com", "www.alterupload.com"], online: true),
        .init(name: "Rapidgator", domains: ["rapidgator.net", "rg.to"], online: false),
        .init(name: "Mega", domains: ["mega.nz"]),
        .init(name: "Busy", domains: ["busy.example"], linksLeft: 0),
    ])

    private func url(_ string: String) -> URL { URL(string: string)! }

    @Test func matchesDomainsAndSubdomains() {
        #expect(list.verdict(for: url("https://1fichier.com/?abc")) == .supported("1Fichier"))
        #expect(list.verdict(for: url("https://www.1fichier.com/?abc")) == .supported("1Fichier"))
        #expect(list.verdict(for: url("https://ALTERUPLOAD.com/x")) == .supported("1Fichier"))
        #expect(list.verdict(for: url("https://dl.mega.nz/file/x")) == .supported("Mega"))
        #expect(list.verdict(for: url("https://notmega.nz/file/x")) == .unsupported)
        #expect(list.verdict(for: url("https://example.com/page")) == .unsupported)
    }

    @Test func downAndUsedUpHostersAreNotWorthTrying() {
        let down = list.verdict(for: url("https://rg.to/file/1"))
        #expect(down == .offline("Rapidgator"))
        #expect(!down.isWorthTrying)
        #expect(list.verdict(for: url("https://busy.example/f")) == .limitReached("Busy"))
        #expect(HostVerdict.unknown.isWorthTrying)
    }

    @Test func realDebridGroupsDomainsByNameWithStatus() async throws {
        let transport = MockTransport()
        await transport.stub("hosts", body: try Fixture.data("realdebrid_hosts"))
        await transport.stub("hosts/status", body: try Fixture.data("realdebrid_hosts_status"))
        let backend = RealDebridBackend(apiKey: "k", transport: transport)

        let hosts = try await backend.hostList()

        let fichier = try #require(hosts.hosts.first { $0.name == "1Fichier" })
        #expect(fichier.domains == ["1fichier.com", "alterupload.com"])
        #expect(fichier.online == true)
        #expect(hosts.verdict(for: url("https://rapidgator.net/file/1")) == .offline("RapidGator"))
    }

    @Test func realDebridWithoutStatusLeavesStateUnknown() async throws {
        let transport = MockTransport()
        await transport.stub("hosts", body: try Fixture.data("realdebrid_hosts"))
        await transport.stub("hosts/status", status: 401, json: #"{"error":"bad_token","error_code":8}"#)
        let hosts = try await RealDebridBackend(apiKey: "k", transport: transport).hostList()
        #expect(hosts.hosts.allSatisfy { $0.online == nil })
    }

    @Test func torBoxReadsStatusAndDailyLinksLeft() async throws {
        let transport = MockTransport()
        await transport.stub("webdl/hosters", body: try Fixture.data("torbox_webdl_hosters"))
        let hosts = try await TorBoxBackend(apiKey: "k", transport: transport).hostList()

        let fichier = try #require(hosts.hosts.first { $0.name == "1Fichier" })
        #expect(fichier.linksLeft == 49)
        #expect(fichier.online == true)
        // No daily limit (0) means none, not "nothing left".
        #expect(hosts.hosts.first { $0.name == "Pixeldrain" }?.linksLeft == nil)
        #expect(hosts.verdict(for: url("https://rg.to/file/1")) == .offline("Rapidgator"))
        #expect(await transport.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer k")
    }

    @Test func debridLinkStatusZeroIsDown() async throws {
        let transport = MockTransport()
        await transport.stub("downloader/hosts", body: try Fixture.data("debridlink_downloader_hosts"))
        let hosts = try await DebridLinkBackend(apiKey: "k", transport: transport).hostList()

        #expect(hosts.verdict(for: url("https://1fichier.com/?abc")) == .supported("1fichier"))
        #expect(hosts.verdict(for: url("https://down.example/f")) == .offline("downhost"))
        #expect(await transport.requests.first?.url?.query()?.contains("keys=name,type,status,domains") == true)
    }

    @Test func catalogKeepsFreshListsAndSavesThem() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let file = directory.appending(path: "hosts.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = MockTransport()
        await transport.stub("downloader/hosts", body: try Fixture.data("debridlink_downloader_hosts"))
        let backend = DebridLinkBackend(apiKey: "k", transport: transport)

        let catalog = HostCatalog(fileURL: file)
        let first = await catalog.refresh([backend])
        #expect(first[.debridLink] != nil)
        _ = await catalog.refresh([backend])
        #expect(await transport.requests.count == 1)

        // A new process reads the saved copy without asking again.
        let reloaded = HostCatalog(fileURL: file)
        #expect(await reloaded.snapshot[.debridLink]?.hosts.count == 3)
    }

    @Test func catalogKeepsTheOldCopyWhenAFetchFails() async throws {
        let transport = MockTransport()
        await transport.stub("downloader/hosts", body: try Fixture.data("debridlink_downloader_hosts"))
        await transport.stub("downloader/hosts", status: 500, json: #"{"success":false,"error":"server_error"}"#)
        let backend = DebridLinkBackend(apiKey: "k", transport: transport)
        let catalog = HostCatalog(fileURL: nil, maxAge: 0)

        _ = await catalog.refresh([backend])
        let after = await catalog.refresh([backend])
        #expect(after[.debridLink]?.hosts.count == 3)
    }
}
