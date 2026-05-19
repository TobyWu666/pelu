import Foundation

/// Wire format for POST /usage in the multi-Mac protocol. Top-level macId/label
/// identify the sender; the rest matches `UsageSnapshot`.
struct MacUploadEnvelope: Encodable, Sendable {
    let macId: String
    let label: String
    let generatedAt: Date
    let metrics: [UsageMetric]
}

public enum CloudUsageClientError: Error, Equatable, Sendable {
    case missingSharedSecret
    case invalidResponse
    case unacceptableStatusCode(Int)
}

public struct CloudUsageClient: Sendable {
    private let endpoint: URL
    private let sharedSecret: String
    private let session: URLSession
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(
        endpoint: URL = URL(string: "https://pelu.tobywu.org/usage")!,
        sharedSecret: String,
        session: URLSession = .shared,
        encoder: JSONEncoder = .peluAPI,
        decoder: JSONDecoder = .peluAPI
    ) {
        self.endpoint = endpoint
        self.sharedSecret = sharedSecret
        self.session = session
        self.encoder = encoder
        self.decoder = decoder
    }

    /// Fetch the multi-Mac aggregate. Worker returns `{ macs: [...] }`.
    /// Falls back to wrapping a legacy single-snapshot response so old data
    /// during migration doesn't crash the iPhone.
    public func fetchAggregate() async throws -> AggregateSnapshot {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        authorize(&request)

        let (data, response) = try await session.data(for: request)
        try validate(response)

        if let aggregate = try? decoder.decode(AggregateSnapshot.self, from: data) {
            return aggregate
        }
        // Legacy single-snapshot fallback (pre-multi-Mac Worker).
        let legacy = try decoder.decode(UsageSnapshot.self, from: data)
        return AggregateSnapshot(macs: [
            MacSnapshot(macId: "legacy", label: "Mac", snapshot: legacy)
        ])
    }

    /// Upload this Mac's snapshot inside the multi-Mac envelope.
    public func upload(macId: String, label: String, snapshot: UsageSnapshot) async throws {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(MacUploadEnvelope(
            macId: macId,
            label: label,
            generatedAt: snapshot.generatedAt,
            metrics: snapshot.metrics
        ))
        authorize(&request)

        let (_, response) = try await session.data(for: request)
        try validate(response)
    }

    private func authorize(_ request: inout URLRequest) {
        request.setValue("Bearer \(sharedSecret)", forHTTPHeaderField: "Authorization")
    }

    private func validate(_ response: URLResponse) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CloudUsageClientError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw CloudUsageClientError.unacceptableStatusCode(httpResponse.statusCode)
        }
    }
}

