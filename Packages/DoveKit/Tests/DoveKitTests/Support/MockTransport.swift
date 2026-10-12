import Foundation
@testable import DoveKit

/// Returns canned responses keyed by the last path components of the URL, and records every request.
/// Stubbing the same path again queues another response; the last one repeats.
actor MockTransport: HTTPTransport {
    struct Stub {
        var status: Int = 200
        var body: Data
    }

    private var stubs: [String: [Stub]] = [:]
    private(set) var requests: [URLRequest] = []

    func stub(_ pathSuffix: String, status: Int = 200, body: Data) {
        stubs[pathSuffix, default: []].append(Stub(status: status, body: body))
    }

    func stub(_ pathSuffix: String, status: Int = 200, json: String) {
        stub(pathSuffix, status: status, body: Data(json.utf8))
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let path = request.url?.path ?? ""
        guard let key = stubs.keys.filter({ path.hasSuffix($0) }).max(by: { $0.count < $1.count }),
              let match = stubs[key]?.first
        else { throw URLError(.unsupportedURL) }
        if stubs[key]!.count > 1 { stubs[key]!.removeFirst() }
        let response = HTTPURLResponse(url: request.url!, statusCode: match.status, httpVersion: nil, headerFields: nil)!
        return (match.body, response)
    }
}

enum Fixture {
    static func data(_ name: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures") else {
            throw URLError(.fileDoesNotExist)
        }
        return try Data(contentsOf: url)
    }
}
