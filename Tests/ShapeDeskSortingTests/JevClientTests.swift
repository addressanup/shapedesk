import XCTest
import Foundation
@testable import ShapeDeskSorting

private actor MockTransport: JevTransport {
    var responses: [Result<HTTPResult, URLError>]
    private(set) var requests: [URLRequest] = []

    init(_ responses: [Result<HTTPResult, URLError>]) { self.responses = responses }

    func send(_ request: URLRequest) async throws -> HTTPResult {
        requests.append(request)
        guard !responses.isEmpty else { throw URLError(.badServerResponse) }
        return try responses.removeFirst().get()
    }
}

private actor DelayRecorder {
    private(set) var delays: [TimeInterval] = []
    func add(_ delay: TimeInterval) { delays.append(delay) }
}

final class JevClientTests: XCTestCase {
    private var metadata: FileMetadata {
        FileMetadata(name: "Screen Recording 2026-10-05.mov", fileExtension: "mov", byteSize: 123456,
                     contentType: "com.apple.quicktime-movie", mimeType: "video/quicktime",
                     createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                     modifiedAt: Date(timeIntervalSince1970: 1_700_000_100))
    }

    private func response(confidence: Any = 0.99, choice: String = "Recordings",
                          type: String = "choice", probabilities: [String: Double]? = nil,
                          answerKey: String = "category") throws -> Data {
        let probabilities = probabilities ?? Dictionary(uniqueKeysWithValues:
            FileCategory.allCases.map { ($0.rawValue, $0 == .recordings ? 0.993 : 0.001) })
        return try JSONSerialization.data(withJSONObject: [
            "model": "jev-1.13.0",
            "answers": [answerKey: ["type": type, "choice": choice,
                                     "confidence": confidence, "probabilities": probabilities]],
            "usage": ["input_tokens": 100, "output_tokens": 10]
        ])
    }

    private func result(status: Int = 200, data: Data? = nil, retryAfter: String? = nil) throws -> Result<HTTPResult, URLError> {
        .success(HTTPResult(data: try data ?? response(), status: status, retryAfter: retryAfter))
    }

    func testDocumentedAPIContractAndMetadataOnlyPayload() async throws {
        let transport = MockTransport([try result()])
        let client = try JevClient(apiKey: "test-only-key", transport: transport)
        let decision = try await client.classify(metadata)
        XCTAssertEqual(decision.category, .recordings)
        XCTAssertEqual(decision.confidence, 0.99)
        XCTAssertEqual(decision.model, "jev-1.13.0")
        let requests = await transport.requests
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://api.typesafe.ai/v1/systemone")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-only-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(payload["model"] as? String, JevClient.model)
        let state = try XCTUnwrap(payload["state"] as? [String: Any])
        XCTAssertEqual(Set(state.keys), ["name", "fileExtension", "byteSize", "contentType", "mimeType", "createdAt", "modifiedAt"])
        XCTAssertEqual(state["name"] as? String, metadata.name)
        let questions = try XCTUnwrap(payload["questions"] as? [String: [String: Any]])
        XCTAssertEqual(Set(questions.keys), ["category"])
        let question = try XCTUnwrap(questions["category"])
        XCTAssertEqual(question["type"] as? String, "choice")
        let criteria = try XCTUnwrap(question["criteria"] as? [String: String])
        XCTAssertEqual(Set(criteria.keys), Set(["Screenshots", "Recordings", "Videos", "Audio", "Images", "Docs", "Code", "Other"]))
        XCTAssertTrue(criteria.values.allSatisfy { !$0.isEmpty })
    }

    func testConfidenceIsNotSubstitutedWithWinningProbability() async throws {
        for (confidence, expected) in [(0.8, false), (0.8000001, true)] {
            let client = try JevClient(apiKey: "test", transport: MockTransport([try result(data: response(confidence: confidence))]))
            let decision = try await client.classify(metadata)
            XCTAssertEqual(decision.permitsMove, expected)
            // The selected option has 0.993 probability in both responses.
            XCTAssertEqual(decision.confidence, confidence)
        }
    }

    func testMissingAndInvalidAPIKeysAreRejected() {
        for key in ["", "  \n ", "abc\ndef", "abc\rdef"] {
            XCTAssertThrowsError(try JevClient(apiKey: key))
        }
    }

    func testInvalidResponseShapesAndValuesAreRejected() throws {
        let badData = [
            Data("not JSON".utf8), Data("{}".utf8),
            try response(confidence: -0.01), try response(confidence: 1.01),
            try response(confidence: "0.99"), try response(confidence: NSNull()),
            try response(choice: "../../Desktop"), try response(type: "score"),
            try response(answerKey: "wrong_id"), try response(probabilities: ["Recordings": 1]),
            try response(choice: "Docs")
        ]
        for data in badData { XCTAssertThrowsError(try JevClient.decode(data)) }
        var probabilities = Dictionary(uniqueKeysWithValues: FileCategory.allCases.map { ($0.rawValue, 0.2) })
        XCTAssertThrowsError(try JevClient.decode(response(probabilities: probabilities)))
        probabilities["Recordings"] = -1
        XCTAssertThrowsError(try JevClient.decode(response(probabilities: probabilities)))
        let missingConfidence = """
        {"model":"jev-1.13.0","answers":{"category":{"type":"choice","choice":"Docs","probabilities":{"Docs":1}}}}
        """
        XCTAssertThrowsError(try JevClient.decode(Data(missingConfidence.utf8)))
    }

    func testRateLimitsAndOverloadRetryWithBoundedBackoff() async throws {
        let transport = MockTransport([try result(status: 429, retryAfter: "0.25"),
                                       try result(status: 529), try result()])
        let recorder = DelayRecorder()
        let client = try JevClient(apiKey: "test", transport: transport, sleep: { await recorder.add($0) })
        let decision = try await client.classify(metadata)
        XCTAssertEqual(decision.category, .recordings)
        let delays = await recorder.delays
        XCTAssertEqual(delays, [0.25, 2])
        let count = await transport.requests.count
        XCTAssertEqual(count, 3)
    }

    func testRetriesAreLimitedAndLongRetryAfterIsNotIgnored() async throws {
        for header in [nil, "60"] as [String?] {
            let transport = MockTransport(Array(repeating: try result(status: 429, retryAfter: header), count: 3))
            let client = try JevClient(apiKey: "test", transport: transport, sleep: { _ in })
            do { _ = try await client.classify(metadata); XCTFail("Expected rate-limit failure") }
            catch JevError.http(let status) { XCTAssertEqual(status, 429) }
            let count = await transport.requests.count
            XCTAssertEqual(count, header == nil ? 3 : 1)
        }
    }

    func testAuthenticationAndValidationFailuresAreNotRetried() async throws {
        for status in [301, 401, 403, 422] {
            let transport = MockTransport([try result(status: status)])
            let client = try JevClient(apiKey: "test", transport: transport)
            do { _ = try await client.classify(metadata); XCTFail("Expected HTTP failure") }
            catch JevError.http(let received) { XCTAssertEqual(received, status) }
            let count = await transport.requests.count
            XCTAssertEqual(count, 1)
        }
    }

    func testNetworkTimeoutAndMalformedResponsePropagateWithoutClassification() async throws {
        let cases: [Result<HTTPResult, URLError>] = [
            .failure(URLError(.timedOut)), .failure(URLError(.notConnectedToInternet)),
            try result(data: Data("{bad response}".utf8))
        ]
        for item in cases {
            let client = try JevClient(apiKey: "test", transport: MockTransport([item]))
            do { _ = try await client.classify(metadata); XCTFail("Expected processing failure") }
            catch { /* The engine catches this error and retains the file. */ }
        }
    }

    func testCancellationDuringBackoffStopsAdditionalRequests() async throws {
        let waiting = expectation(description: "Backoff started")
        let transport = MockTransport([try result(status: 429), try result()])
        let client = try JevClient(apiKey: "test", transport: transport, sleep: { _ in
            waiting.fulfill()
            try await Task.sleep(nanoseconds: 10_000_000_000)
        })
        let fileMetadata = metadata
        let operation = Task { try await client.classify(fileMetadata) }
        await fulfillment(of: [waiting], timeout: 2)
        operation.cancel()
        do { _ = try await operation.value; XCTFail("Expected cancellation") }
        catch is CancellationError {}
        let count = await transport.requests.count
        XCTAssertEqual(count, 1)
    }

    func testRetryAfterHTTPDateAndInvalidHeaders() {
        let now = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(JevClient.retryDelay("Thu, 01 Jan 1970 00:00:04 GMT", attempt: 0, now: now), 4)
        XCTAssertEqual(JevClient.retryDelay("invalid", attempt: 1, now: now), 2)
        XCTAssertEqual(JevClient.retryDelay("-4", attempt: 0, now: now), 1)
        XCTAssertEqual(JevClient.retryDelay("nan", attempt: 0, now: now), 1)
    }
}
