import Foundation

final class URLProtocolStub: URLProtocol {
    struct Response {
        let statusCode: Int
        let body: Data
        let headers: [String: String]
        init(statusCode: Int = 200, body: Data, headers: [String: String] = ["Content-Type": "application/json"]) {
            self.statusCode = statusCode
            self.body = body
            self.headers = headers
        }
    }

    /// Maps URL.path to a queue of canned responses. Each request consumes the head.
    static var responses: [String: [Response]] = [:]
    /// All URL.paths that the stub has been asked to serve, in order.
    static var requestedPaths: [String] = []
    /// Bodies attached to each request keyed by URL.path (last write wins).
    static var requestBodies: [String: Data] = [:]

    static func reset() {
        responses = [:]
        requestedPaths = []
        requestBodies = [:]
    }

    static func enqueue(path: String, response: Response) {
        responses[path, default: []].append(response)
    }

    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [URLProtocolStub.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path ?? ""
        URLProtocolStub.requestedPaths.append(path)

        // Capture body — URLSession strips httpBody when uploading from a file or
        // stream, so fall back to httpBodyStream when needed.
        if let body = request.httpBody {
            URLProtocolStub.requestBodies[path] = body
        } else if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            let bufferSize = 4096
            var buffer = [UInt8](repeating: 0, count: bufferSize)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: bufferSize)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            URLProtocolStub.requestBodies[path] = data
        }

        guard var queue = URLProtocolStub.responses[path], !queue.isEmpty else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let response = queue.removeFirst()
        URLProtocolStub.responses[path] = queue

        let httpResponse = HTTPURLResponse(
            url: request.url!,
            statusCode: response.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: response.headers
        )!
        client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() { }
}
