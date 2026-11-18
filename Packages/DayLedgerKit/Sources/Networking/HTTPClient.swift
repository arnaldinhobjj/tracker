import Foundation

/// Minimal async HTTP abstraction so API clients can be unit tested with stubs.
public protocol HTTPClient: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionHTTPClient: HTTPClient {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw NetworkError.invalidResponse }
            return (data, http)
        } catch let error as URLError {
            throw NetworkError(error)
        } catch is CancellationError {
            throw NetworkError.cancelled
        }
    }
}

public extension HTTPClient {
    /// Sends the request and throws a `NetworkError` for any non-2xx status.
    func sendValidated(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await send(request)
        try Self.validate(response: response, data: data)
        return data
    }

    /// Sends the request, validates the status code and decodes the JSON body.
    func decode<T: Decodable>(_ type: T.Type, from request: URLRequest, decoder: JSONDecoder = JSONDecoder()) async throws -> T {
        let data = try await sendValidated(request)
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw NetworkError.decoding(String(describing: error))
        }
    }

    static func validate(response: HTTPURLResponse, data: Data) throws {
        guard !(200..<300).contains(response.statusCode) else { return }
        // Keep error bodies short; they never contain tokens but may be large HTML pages.
        let body = String(data: data.prefix(1_000), encoding: .utf8)
        switch response.statusCode {
        case 401: throw NetworkError.unauthorized(body: body)
        case 403: throw NetworkError.forbidden(body: body)
        default: throw NetworkError.http(status: response.statusCode, body: body)
        }
    }
}

public enum FormURLEncoding {
    /// Encodes parameters as `application/x-www-form-urlencoded`, sorted by key for stable output.
    public static func encode(_ parameters: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let body = parameters
            .sorted { $0.key < $1.key }
            .map { key, value in
                let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
                let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
                return "\(k)=\(v)"
            }
            .joined(separator: "&")
        return Data(body.utf8)
    }
}

public extension URLRequest {
    static func formPost(url: URL, parameters: [String: String]) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = FormURLEncoding.encode(parameters)
        return request
    }

    mutating func setBearer(_ token: String) {
        setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }
}
