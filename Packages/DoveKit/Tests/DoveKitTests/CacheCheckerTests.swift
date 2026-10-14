import Foundation
import Testing
@testable import DoveKit

struct CacheCheckerTests {
    private let hashA = "3133f1ac4b86226ca105e69b1c1374ef552380b5"
    private let hashB = "43769698196be768c3d9e6afd6896b00bc978d0c"

    @Test func torBoxAsksForAllHashesInOneListCall() async throws {
        let transport = MockTransport()
        await transport.stub("torrents/checkcached", json: #"{"success":true,"data":[{"name":"x","size":1,"hash":"\#(hashA.uppercased())"}]}"#)
        let torBox = TorBoxBackend(apiKey: "k", transport: transport)

        let cached = try await torBox.cachedHashes([hashA, hashB])

        #expect(cached == [hashA])
        let sent = try #require(await transport.requests.last)
        let query = URLComponents(url: sent.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(query.contains(URLQueryItem(name: "hash", value: "\(hashA),\(hashB)")))
        #expect(query.contains(URLQueryItem(name: "format", value: "list")))
        #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer k")
    }

    @Test func torBoxNullDataMeansNothingCached() async throws {
        let transport = MockTransport()
        await transport.stub("torrents/checkcached", json: #"{"success":true,"data":null}"#)
        #expect(try await TorBoxBackend(apiKey: "k", transport: transport).cachedHashes([hashA]).isEmpty)
    }

    @Test func offcloudPostsHashesAndReadsHitsOnly() async throws {
        let transport = MockTransport()
        await transport.stub("cache/info", json: #"[{"cached":false},{"cached":true}]"#)
        let offcloud = OffcloudBackend(apiKey: "k", transport: transport)

        let cached = try await offcloud.cachedHashes([hashA, hashB.uppercased()])

        // Answers come back in the order of the URLs sent.
        #expect(cached == [hashB])
        let sent = try #require(await transport.requests.last)
        #expect(sent.httpMethod == "POST")
        #expect(sent.url?.path.hasSuffix("/api/cache/info") == true)
        let body = try JSONSerialization.jsonObject(with: sent.httpBody ?? Data()) as? [String: [String]]
        #expect(body?["urls"] == ["magnet:?xt=urn:btih:\(hashA)", "magnet:?xt=urn:btih:\(hashB)"])
    }

    @Test func offcloudShortAnswerIsInvalid() async {
        let transport = MockTransport()
        await transport.stub("cache/info", json: #"[{"cached":true}]"#)
        await #expect(throws: BackendError.invalidResponse) {
            try await OffcloudBackend(apiKey: "k", transport: transport).cachedHashes([hashA, hashB])
        }
    }

    @Test func annotateMarksCachedAndKnownMisses() async throws {
        let torBoxTransport = MockTransport()
        await torBoxTransport.stub("torrents/checkcached", json: #"{"success":true,"data":[{"hash":"\#(hashA)"}]}"#)
        let offcloudTransport = MockTransport()
        await offcloudTransport.stub("cache/info", status: 500, json: #"{"error":"down"}"#)
        let groups = StreamGroup.group([
            StreamCandidate(id: "1", kind: .p2p, title: "A.S01E01.1080p", infoHash: hashA),
            StreamCandidate(id: "2", kind: .p2p, title: "B.S01E01.1080p", infoHash: hashB, service: "realdebrid", cached: true),
            StreamCandidate(id: "3", kind: .debrid, title: "No hash")
        ])

        let annotated = await CacheChecker.annotate(groups, using: [
            TorBoxBackend(apiKey: "k", transport: torBoxTransport),
            OffcloudBackend(apiKey: "k", transport: offcloudTransport)
        ])

        #expect(annotated[0].cachedBackends() == [.torBox])
        // TorBox answered "no" for B; the addon's RD report stays; Offcloud failed, so it says nothing.
        #expect(annotated[1].availability.map(\.service) == ["realdebrid", "torbox"])
        #expect(annotated[1].availability.map(\.cached) == [true, false])
        #expect(annotated[2].availability.isEmpty)
    }

    @Test func checkedMissDoesNotOverrideAnAddonsHit() {
        var group = StreamGroup.group([StreamCandidate(id: "1", kind: .debrid, title: "A", infoHash: hashA, service: "torbox", cached: true)])[0]
        group.record(service: "torbox", cached: false)
        #expect(group.cachedBackends() == [.torBox])
    }
}

struct AIOStreamsValidationTests {
    private func client(_ transport: MockTransport) -> AIOStreamsSearch {
        AIOStreamsSearch(origin: URL(string: "https://aio.example")!, uuid: "u", password: "p", transport: transport)
    }

    @Test func validPasswordPasses() async throws {
        let transport = MockTransport()
        await transport.stub("api/v1/user", json: #"{"success":true,"detail":"ok","data":{"userData":{"services":[{"credentials":{"apiKey":"SECRET"}}]}}}"#)
        try await client(transport).validate()
        #expect(await transport.requests.last?.value(forHTTPHeaderField: "Authorization") == "Basic " + Data("u:p".utf8).base64EncodedString())
    }

    @Test func variantsAreReadWithoutScripts() async throws {
        let transport = MockTransport()
        await transport.stub("api/v1/user", json: #"{"success":true,"data":{"userData":{"variants":[{"id":"dove","name":"Dove","enabled":true,"script":"set services[id=realdebrid].credentials.apiKey = \"SECRET\""},{"id":"phone","enabled":false,"script":""}]}}}"#)

        let variants = try await client(transport).variants()

        #expect(variants.map(\.id) == ["dove", "phone"])
        #expect(variants.map(\.enabled) == [true, false])
        #expect(variants[0].displayName == "Dove (dove)")
    }

    @Test func addVariantKeepsEveryOtherFieldAndAppends() async throws {
        let transport = MockTransport()
        await transport.stub("api/v1/user", json: #"{"success":true,"data":{"userData":{"uuid":"u","services":[{"id":"torbox","credentials":{"apiKey":"enc:abc"}}],"variants":[{"id":"phone","enabled":true,"script":"set resultLimits.global = 10"}],"futureField":{"x":1}},"encryptedPassword":"e"}}"#)
        await transport.stub("api/v1/user", json: #"{"success":true,"detail":"User updated successfully","data":{"uuid":"u"}}"#)

        try await client(transport).saveDoveVariant()

        let requests = await transport.requests
        #expect(requests.count == 2)
        #expect(requests[0].url?.query() == "raw=true")
        let put = try #require(requests.last)
        #expect(put.httpMethod == "PUT")
        let body = try #require(try JSONSerialization.jsonObject(with: put.httpBody ?? Data()) as? [String: Any])
        let config = try #require(body["config"] as? [String: Any])
        #expect((config["futureField"] as? [String: Int])?["x"] == 1)
        #expect(((config["services"] as? [[String: Any]])?.first?["credentials"] as? [String: String])?["apiKey"] == "enc:abc")
        let variants = try #require(config["variants"] as? [[String: Any]])
        #expect(variants.compactMap { $0["id"] as? String } == ["phone", "dove"])
        #expect((variants.last?["script"] as? String)?.contains("clear excludedStreamExpressions") == true)
    }

    @Test func existingDoveVariantIsRewrittenNotDuplicated() async throws {
        let transport = MockTransport()
        await transport.stub("api/v1/user", json: #"{"success":true,"data":{"userData":{"variants":[{"id":"dove","name":"Mine","enabled":false,"script":"old"},{"id":"phone","script":"keep"}]}}}"#)
        await transport.stub("api/v1/user", json: #"{"success":true,"data":{}}"#)

        try await client(transport).saveDoveVariant()

        let put = try #require(await transport.requests.last)
        let body = try #require(try JSONSerialization.jsonObject(with: put.httpBody ?? Data()) as? [String: Any])
        let variants = try #require((body["config"] as? [String: Any])?["variants"] as? [[String: Any]])
        #expect(variants.count == 2)
        #expect(variants[0]["name"] as? String == "Mine", "the user's name stays")
        #expect(variants[0]["enabled"] as? Bool == true)
        #expect((variants[0]["script"] as? String)?.contains("excludedStreamTypes") == true)
        #expect(variants[1]["script"] as? String == "keep")
    }

    @Test func doveScriptTurnsOffUsenetServicesAndUsenetOrHTTPAddons() {
        let presets: [[String: Any]] = [
            ["type": "usenet-streamer", "instanceId": "a1", "options": ["name": "Usenet Streamer"]],
            ["type": "custom", "instanceId": "b2", "options": ["name": "My NZB thing", "manifestUrl": "https://x.example/manifest.json"]],
            ["type": "custom", "instanceId": "c3", "options": ["name": "Something", "manifestUrl": "https://usenetstreamer.example/t/manifest.json"]],
            ["type": "custom", "instanceId": "d4", "options": ["name": "Torrentio mirror", "manifestUrl": "https://t.example/manifest.json"]],
            ["type": "custom", "instanceId": "e\"5", "options": ["name": "NZB with a quote"]],
            ["type": "torrentio", "instanceId": "f6"],
        ]
        let lines = AIOStreamsSearch.doveVariantScript(presets: presets).split(separator: "\n").map(String.init)

        #expect(lines.contains("disable services[id=nzbdav]"))
        #expect(lines.contains("disable services[id=stremio_nntp]"))
        #expect(lines.contains("disable presets[type=usenet-streamer]"))
        #expect(lines.contains("disable presets[type=easynewsPlus]"))
        #expect(lines.contains("disable presets[type=hdhub]"))
        #expect(lines.contains("remove presets[*].options.services"))
        #expect(lines.contains("remove presets[*].options.httpProviders"))
        #expect(lines.filter { $0.hasPrefix("disable presets[instanceId=") } == [
            #"disable presets[instanceId="b2"]"#,
            #"disable presets[instanceId="c3"]"#,
        ], "custom addons by name or manifest; a quote in an id would break the script")
        #expect(lines.contains(#"set excludedStreamTypes = ["usenet", "stremio-usenet", "http", "live", "youtube", "external"]"#))
        #expect(!lines.contains { $0.contains("p2p") }, "bare info hashes are still torrents Dove can add")
        #expect(!lines.contains { $0.contains("torrentio") })
    }

    @Test func refusedSaveSurfacesTheServerMessage() async {
        let transport = MockTransport()
        await transport.stub("api/v1/user", json: #"{"success":true,"data":{"userData":{}}}"#)
        await transport.stub("api/v1/user", status: 400, json: #"{"success":false,"error":{"code":"USER_INVALID_CONFIG","message":"Config variant \"dove\" line 3: bad"}}"#)
        do {
            try await client(transport).saveDoveVariant()
            Issue.record("expected an error")
        } catch {
            #expect(error.localizedDescription.contains("line 3"))
        }
    }

    @Test func unfilteredScriptOnlyUsesKnownInstructions() {
        let lines = AIOStreamsSearch.unfilteredVariantScript.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        for line in lines where !line.isEmpty && !line.hasPrefix("#") {
            #expect(["unset ", "set ", "clear "].contains { line.hasPrefix($0) }, "\(line)")
        }
    }

    @Test func unknownVariantGetsAReadableMessage() async {
        let transport = MockTransport()
        await transport.stub("api/v1/search", status: 400, json: #"{"success":false,"error":{"code":"USER_INVALID_CONFIG","message":"Unknown config variant \"dove\""},"data":null}"#)
        let client = AIOStreamsSearch(origin: URL(string: "https://aio.example")!, uuid: "u", password: "p", variant: "dove", transport: transport)
        do {
            _ = try await client.search(type: .movie, id: "tt1")
            Issue.record("expected an error")
        } catch {
            #expect(error.localizedDescription.contains("Miscellaneous → Variants"))
        }
    }

    @Test func wrongPasswordIsUnauthorized() async {
        let transport = MockTransport()
        await transport.stub("api/v1/user", status: 401, json: #"{"success":false,"error":{"code":"USER_INVALID_PASSWORD","message":"Invalid password"},"data":null}"#)
        await #expect(throws: BackendError.unauthorized) { try await client(transport).validate() }
    }
}
