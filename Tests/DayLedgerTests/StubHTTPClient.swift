import Foundation
import Networking

/// Records requests and replies with queued responses.
final class StubHTTPClient: HTTPClient, @unchecked Sendable {
    struct Reply {
        let status: Int
        let body: String
    }

    private let lock = NSLock()
    private var replies: [(matches: (URLRequest) -> Bool, reply: Reply)] = []
    private(set) var requests: [URLRequest] = []

    func on(_ pathSuffix: String, status: Int = 200, body: String) {
        lock.withLock {
            replies.append(({ $0.url?.path.hasSuffix(pathSuffix) == true }, Reply(status: status, body: body)))
        }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let reply: Reply? = lock.withLock {
            requests.append(request)
            guard let index = replies.firstIndex(where: { $0.matches(request) }) else { return nil }
            return replies.remove(at: index).reply
        }
        guard let reply else { throw NetworkError.offline }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil, headerFields: nil)!
        return (Data(reply.body.utf8), response)
    }
}

