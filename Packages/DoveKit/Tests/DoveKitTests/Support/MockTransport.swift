import Foundation
@testable import DoveKit

/// Returns canned responses keyed by the last path components of the URL (and, optionally, text the body
/// must contain, for APIs that put everything behind one path), and records every request.
/// Stubbing the same key again queues another response; the last one repeats.
actor MockTransport: HTTPTransport {
    struct Stub {
        var status: Int = 200
        var body: Data
        var contentType = "application/json"
        var headers: [String: String] = [:]
    }

    private struct Key: Hashable {
        var path: String
        var body: String?
        var query: String?
    }

    private var stubs: [Key: [Stub]] = [:]
    private(set) var requests: [URLRequest] = []

    func stub(
        _ pathSuffix: String,
        bodyContains: String? = nil,
        queryContains: String? = nil,
        status: Int = 200,
        body: Data,
        contentType: String = "application/json"
    ) {
        stubs[Key(path: pathSuffix, body: bodyContains, query: queryContains), default: []]
            .append(Stub(status: status, body: body, contentType: contentType))
    }

    func stub(_ pathSuffix: String, bodyContains: String? = nil, queryContains: String? = nil, status: Int = 200, json: String) {
        stub(pathSuffix, bodyContains: bodyContains, queryContains: queryContains, status: status, body: Data(json.utf8))
    }

    /// A bare response with headers (redirects: `Location`).
    func stub(_ pathSuffix: String, queryContains: String? = nil, status: Int, headers: [String: String], body: Data = Data()) {
        stubs[Key(path: pathSuffix, body: nil, query: queryContains), default: []]
            .append(Stub(status: status, body: body, contentType: "application/octet-stream", headers: headers))
    }

    func stub(_ pathSuffix: String, status: Int = 200, html: String) {
        stub(pathSuffix, status: status, body: Data(html.utf8), contentType: "text/html; charset=utf-8")
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let path = request.url?.path ?? ""
        let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        let query = request.url?.query ?? ""
        let candidates = stubs.keys.filter { key in
            path.hasSuffix(key.path) && (key.body.map(body.contains) ?? true) && (key.query.map(query.contains) ?? true)
        }
        // The most specific stub wins: a body or query condition, then the longest path.
        let specificity = { (key: Key) in (key.body == nil && key.query == nil ? 0 : 1, key.path.count) }
        guard let key = candidates.max(by: { specificity($0) < specificity($1) }),
              let match = stubs[key]?.first
        else { throw URLError(.unsupportedURL) }
        if stubs[key]!.count > 1 { stubs[key]!.removeFirst() }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: match.status,
            httpVersion: nil,
            headerFields: ["Content-Type": match.contentType].merging(match.headers) { $1 }
        )!
        return (match.body, response)
    }
}

enum Fixture {
    static func data(_ name: String, extension ext: String = "json") throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures") else {
            throw URLError(.fileDoesNotExist)
        }
        return try Data(contentsOf: url)
    }
}
