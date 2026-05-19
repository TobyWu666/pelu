import Foundation
import PeluCore
import Testing

@Suite(.serialized)
struct CloudUsageClientTests {
    @Test
    func uploadSendsBearerSecretAndEnvelopeWithMacIdLabel() async throws {
        let store = URLProtocolRequestStore()
        let session = URLSession(configuration: .peluMock(store: store))
        let client = CloudUsageClient(
            endpoint: URL(string: "https://pelu.tobywu.org/usage")!,
            sharedSecret: "test-secret",
            session: session
        )

        await store.setHandler { request in
            let body = try #require(request.httpBodyStreamData)
            let envelope = try JSONSerialization.jsonObject(with: body) as? [String: Any]

            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-secret")
            #expect(envelope?["macId"] as? String == "mac-abc")
            #expect(envelope?["label"] as? String == "Test Mac")
            // metrics nests in same envelope
            let metrics = envelope?["metrics"] as? [[String: Any]]
            #expect(metrics?.count == 2)

            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 204,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data()
            )
        }

        try await client.upload(
            macId: "mac-abc",
            label: "Test Mac",
            snapshot: .demo(now: Date(timeIntervalSince1970: 0))
        )
    }

    @Test
    func fetchDecodesAggregateSnapshot() async throws {
        let store = URLProtocolRequestStore()
        let session = URLSession(configuration: .peluMock(store: store))
        let aggregate = AggregateSnapshot(macs: [
            MacSnapshot(macId: "mac-1", label: "Toby's MBP", snapshot: .demo(now: Date(timeIntervalSince1970: 0)))
        ])
        let responseBody = try JSONEncoder.peluAPI.encode(aggregate)
        let client = CloudUsageClient(
            endpoint: URL(string: "https://pelu.tobywu.org/usage")!,
            sharedSecret: "test-secret",
            session: session
        )

        await store.setHandler { request in
            #expect(request.httpMethod == "GET")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-secret")

            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                responseBody
            )
        }

        let decoded = try await client.fetchAggregate()
        #expect(decoded == aggregate)
    }

    @Test
    func fetchFallsBackToLegacySingleSnapshot() async throws {
        let store = URLProtocolRequestStore()
        let session = URLSession(configuration: .peluMock(store: store))
        let legacy = UsageSnapshot.demo(now: Date(timeIntervalSince1970: 0))
        let responseBody = try JSONEncoder.peluAPI.encode(legacy)
        let client = CloudUsageClient(
            endpoint: URL(string: "https://pelu.tobywu.org/usage")!,
            sharedSecret: "test-secret",
            session: session
        )

        await store.setHandler { request in
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                responseBody
            )
        }

        let decoded = try await client.fetchAggregate()
        #expect(decoded.macs.count == 1)
        #expect(decoded.macs.first?.snapshot == legacy)
    }
}
