import Foundation

// MARK: - Request store

actor URLProtocolRequestStore {
    typealias Handler = (URLRequest) async throws -> (HTTPURLResponse, Data)

    private var handler: Handler?

    func setHandler(_ handler: @escaping Handler) {
        self.handler = handler
    }

    func handle(_ request: URLRequest) async throws -> (HTTPURLResponse, Data) {
        guard let h = handler else { fatalError("URLProtocolRequestStore: no handler set") }
        return try await h(request)
    }
}

// MARK: - URLProtocol

final class PeluMockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var store: URLProtocolRequestStore?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let store = PeluMockURLProtocol.store,
              let client = self.client else { return }
        let request = self.request
        Task {
            do {
                let (response, data) = try await store.handle(request)
                client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client.urlProtocol(self, didLoad: data)
                client.urlProtocolDidFinishLoading(self)
            } catch {
                client.urlProtocol(self, didFailWithError: error)
            }
        }
    }

    override func stopLoading() {}
}

// MARK: - URLSessionConfiguration helper

extension URLSessionConfiguration {
    static func peluMock(store: URLProtocolRequestStore) -> URLSessionConfiguration {
        PeluMockURLProtocol.store = store
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PeluMockURLProtocol.self]
        return config
    }
}

// MARK: - URLRequest body helper

extension URLRequest {
    var httpBodyStreamData: Data? {
        if let body = httpBody { return body }
        guard let stream = httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufSize = 4096
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
        defer { buf.deallocate() }
        while stream.hasBytesAvailable {
            let n = stream.read(buf, maxLength: bufSize)
            if n > 0 { data.append(buf, count: n) }
        }
        return data
    }
}
