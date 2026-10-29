#if DEBUG
import Foundation

public struct DemoTransport: HTTPTransport {
    public init() {}
    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        DemoServer.respond(to: request)
    }
}
#endif
