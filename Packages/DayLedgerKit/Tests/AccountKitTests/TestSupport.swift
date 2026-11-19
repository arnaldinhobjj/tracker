import Foundation
import Networking

/// Records requests and replies with queued responses, optionally after a delay.
final class StubHTTPClient: HTTPClient, @unchecked Sendable {
    struct Reply {
        let status: Int
        let body: String
    }

    private let lock = NSLock()
    private var replies: [(matches: (URLRequest) -> Bool, reply: Reply)] = []
    private var _requests: [URLRequest] = []
    /// Applied to every reply, so concurrent callers really overlap.
    var delayNanoseconds: UInt64 = 0

    var requests: [URLRequest] { lock.withLock { _requests } }

    func on(_ pathSuffix: String, status: Int = 200, body: String) {
        lock.withLock {
            replies.append(({ $0.url?.path.hasSuffix(pathSuffix) == true }, Reply(status: status, body: body)))
        }
    }

    func requests(to pathSuffix: String) -> [URLRequest] {
        requests.filter { $0.url?.path.hasSuffix(pathSuffix) == true }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let reply: Reply? = lock.withLock {
            _requests.append(request)
            guard let index = replies.firstIndex(where: { $0.matches(request) }) else { return nil }
            return replies.remove(at: index).reply
        }
        if delayNanoseconds > 0 { try? await Task.sleep(nanoseconds: delayNanoseconds) }
        guard let reply else { throw NetworkError.offline }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil, headerFields: nil)!
        return (Data(reply.body.utf8), response)
    }
}

extension URLRequest {
    /// The JSON body as a dictionary.
    func jsonBody() -> [String: Any]? {
        guard let httpBody else { return nil }
        return (try? JSONSerialization.jsonObject(with: httpBody)) as? [String: Any]
    }

    func queryValue(_ name: String) -> String? {
        url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value }
    }
}
