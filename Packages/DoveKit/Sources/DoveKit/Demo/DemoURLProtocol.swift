#if DEBUG
import Foundation

public final class DemoURLProtocol: URLProtocol, @unchecked Sendable {
    public override class func canInit(with request: URLRequest) -> Bool {
        guard let scheme = request.url?.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
            return false
        }
        return !["commons.wikimedia.org", "upload.wikimedia.org", "thumb.wikimedia.org"].contains(
            request.url?.host?.lowercased() ?? ""
        )
    }
    public override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    public override func startLoading() {
        let (data, response) = DemoServer.respond(to: request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    public override func stopLoading() {}
}
#endif
