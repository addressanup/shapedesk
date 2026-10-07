import XCTest
import Foundation
@testable import ShapeDeskSorting

private actor ProTransport: JevTransport {
    var responses: [Result<HTTPResult, URLError>]
    private(set) var requests: [URLRequest] = []
    init(_ responses: [Result<HTTPResult, URLError>]) { self.responses = responses }
    func send(_ request: URLRequest) async throws -> HTTPResult {
        requests.append(request)
        return try responses.removeFirst().get()
    }
}

final class ProClientTests: XCTestCase {
    private let credentials = ProCredentials(licenseKey: "customer-license", instanceID: "BBBBBBBB-0000-4000-8000-000000000001")
    private var file: FileMetadata {
        FileMetadata(name: "test.pdf", fileExtension: "pdf", byteSize: 123,
            contentType: nil, mimeType: nil, createdAt: Date(), modifiedAt: Date())
    }
    private var usage: [String: Any] { ["active": true, "limit": 1000, "used": 1, "resetsAt": "2026-11-01T00:00:00.000Z"] }
    private func result(_ body: [String: Any], status: Int = 200) throws -> Result<HTTPResult, URLError> {
        .success(HTTPResult(data: try JSONSerialization.data(withJSONObject: body), status: status, retryAfter: nil))
    }
    private func client(_ transport: ProTransport) throws -> ProClient {
        try ProClient(baseURL: URL(string: "https://api.shapedesk.test")!, transport: transport, sleep: {})
    }

    func testHostedClassificationAndStrictThresholdUsesCustomerCredentialOnly() async throws {
        for (confidence, expected) in [(0.8, false), (0.800001, true)] {
            let transport = ProTransport([try result(["category": "Docs", "confidence": confidence, "model": "jev-1.13.0", "entitlement": usage])])
            let (decision, entitlement) = try await client(transport).classify(file, credentials: credentials)
            XCTAssertEqual(decision.permitsMove, expected)
            XCTAssertEqual(entitlement.remaining, 999)
            let requests = await transport.requests
            let request = try XCTUnwrap(requests.first)
            XCTAssertEqual(request.url?.absoluteString, "https://api.shapedesk.test/v1/classify")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer customer-license")
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
            XCTAssertNotNil(UUID(uuidString: body["requestID"] as? String ?? ""))
            XCTAssertEqual(Set(body.keys), ["requestID", "metadata"])
        }
    }

    func testLostResponseRetriesSameIDAndPayload() async throws {
        let transport = ProTransport([.failure(URLError(.networkConnectionLost)), try result([
            "category": "Docs", "confidence": 0.9, "model": "jev-1.13.0", "entitlement": usage])])
        _ = try await client(transport).classify(file, credentials: credentials)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].httpBody, requests[1].httpBody)
    }

    func testQuotaAndInactiveStopFurtherNetworkCallsForThisSort() async throws {
        for (code, status) in [("quota_exhausted", 402), ("inactive", 401)] {
            let transport = ProTransport([try result(["code": code], status: status)])
            let classifier = HostedClassifier(client: try client(transport), credentials: credentials)
            for _ in 0..<3 {
                do { _ = try await classifier.classify(file); XCTFail("Must fail closed") } catch { XCTAssertTrue(error is ProError) }
            }
            let requests = await transport.requests
            XCTAssertEqual(requests.count, 1)
        }
    }

    func testInvalidClassificationResponsesAreRejected() async throws {
        for value: [String: Any] in [
            ["category": "Unknown", "confidence": 0.9, "model": "jev", "entitlement": usage],
            ["category": "Docs", "confidence": 1.1, "model": "jev", "entitlement": usage],
            ["category": "Docs", "confidence": 0.9, "model": "", "entitlement": usage],
            ["category": "Docs", "confidence": 0.9, "model": "jev", "entitlement": ["active": true, "limit": 10, "used": -1, "resetsAt": "garbage"]]
        ] {
            do { _ = try await client(ProTransport([try result(value)])).classify(file, credentials: credentials); XCTFail() }
            catch { XCTAssertEqual(error as? ProError, .invalidResponse) }
        }
    }

    func testHTTPSIsRequiredAndCredentialsCannotEnterURL() {
        for endpoint in ["http://api.example.com", "http://127.0.0.1:8787", "https://user:pass@example.com", "https://example.com?token=secret", "https://example.com#secret"] {
            XCTAssertThrowsError(try ProClient(baseURL: URL(string: endpoint)!))
        }
    }

    #if SHAPEDESK_OWNER_PREVIEW
    func testOwnerPreviewAllowsOnlyLiteralLoopbackWithoutURLCredentials() throws {
        _ = try ProClient.ownerPreview(baseURL: URL(string: "http://127.0.0.1:8787")!)
        for endpoint in ["http://localhost:8787", "http://127.0.0.1", "http://127.0.0.1:80",
                         "https://127.0.0.1:8787", "http://example.com:8787", "http://127.0.0.1:8787/path",
                         "http://user:pass@127.0.0.1:8787", "http://127.0.0.1:8787?secret=value",
                         "http://127.0.0.1:8787#fragment"] {
            XCTAssertThrowsError(try ProClient.ownerPreview(baseURL: URL(string: endpoint)!))
        }
    }
    #endif

    func testActivationEntitlementAndDeactivationContract() async throws {
        let transport = ProTransport([try result(["instanceID": credentials.instanceID, "entitlement": usage]),
            try result(usage), try result(["deactivated": true])])
        let client = try client(transport)
        let (activated, _) = try await client.activate(licenseKey: credentials.licenseKey, deviceID: UUID().uuidString)
        XCTAssertEqual(activated.instanceID, credentials.instanceID)
        _ = try await client.entitlement(activated)
        try await client.deactivate(activated)
        let requests = await transport.requests
        XCTAssertEqual(requests.map(\.httpMethod), ["POST", "GET", "POST"])
    }

    func testHostedServiceErrorPreservesFileAndUndoNeedsNoSubscription() async throws {
        let fixture = try DesktopFixture()
        try fixture.file("one.pdf")
        let transport = ProTransport([try result(["code": "quota_exhausted"], status: 402)])
        let classifier = HostedClassifier(client: try client(transport), credentials: credentials)
        let failed = await fixture.sorter().sort(using: classifier)
        XCTAssertEqual(failed.moved, 0)
        XCTAssertTrue(fixture.exists("one.pdf"))
        _ = await fixture.sorter().sort(using: StubClassifier())
        let restored = await fixture.sorter().undoLastSort()
        XCTAssertEqual(restored.restored, 1)
    }

    func testRedeemSendsPurchaseSecretAndDecodesEntitlement() async throws {
        let purchase = ProPurchase(deviceID: "AAAAAAAA-0000-4000-8000-000000000002")
        let couponUsage: [String: Any] = ["active": true, "limit": 1000, "used": 0,
            "resetsAt": "2026-11-01T00:00:00.000Z", "account": "0f9308ef8c82",
            "accessType": "coupon", "subscriptionStatus": "active",
            "renewsAt": "2026-10-21T00:00:00.000Z", "canManageBilling": false]
        let transport = ProTransport([try result(["instanceID": credentials.instanceID, "entitlement": couponUsage])])
        let (fresh, entitlement) = try await client(transport).redeem(purchase, code: " beta-friends ")
        XCTAssertEqual(fresh.licenseKey, purchase.licenseKey)
        XCTAssertEqual(fresh.instanceID, credentials.instanceID)
        XCTAssertEqual(entitlement.accessType, "coupon")
        XCTAssertEqual(entitlement.account, "0f9308ef8c82")
        XCTAssertEqual(entitlement.canManageBilling, false)
        let sentRequests = await transport.requests
        let request = try XCTUnwrap(sentRequests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://api.shapedesk.test/v1/redeem")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["licenseKey"] as? String, purchase.licenseKey)
        XCTAssertEqual(body["code"] as? String, "beta-friends")
        XCTAssertEqual(body["deviceID"] as? String, purchase.deviceID)
    }

    func testRedeemMapsCouponErrorsAndRejectsBlankCodes() async throws {
        let purchase = ProPurchase(deviceID: UUID().uuidString)
        for (code, expected) in [("coupon_invalid", ProError.invalidCoupon), ("coupon_revoked", .invalidCoupon),
                                 ("coupon_expired", .couponExpired), ("coupon_exhausted", .couponExhausted),
                                 ("already_redeemed", .couponRedeemed), ("already_subscribed", .alreadySubscribed),
                                 ("account_suspended", .accountSuspended)] {
            let transport = ProTransport([try result(["code": code], status: 409)])
            do { _ = try await client(transport).redeem(purchase, code: "TEST"); XCTFail(code) }
            catch { XCTAssertEqual(error as? ProError, expected, code) }
        }
        let transport = ProTransport([])
        do { _ = try await client(transport).redeem(purchase, code: "   "); XCTFail() }
        catch { XCTAssertEqual(error as? ProError, .invalidCoupon) }
        let requestCount = await transport.requests.count
        XCTAssertEqual(requestCount, 0)
    }

    func testCheckoutUsesPersistentPurchaseProofAndValidatesStripeDestinations() async throws {
        let purchase = ProPurchase(deviceID: UUID().uuidString)
        XCTAssertEqual(purchase.licenseKey.count, 67)
        let valid = try result(["sessionID": "cs_test", "url": "https://checkout.stripe.com/c/pay/test", "expiresAt": "2026-11-01T00:00:00.000Z"])
        let transport = ProTransport([valid, valid, try result(["instanceID": credentials.instanceID, "entitlement": usage])])
        let client = try client(transport)
        _ = try await client.checkout(purchase)
        _ = try await client.checkout(purchase)
        let (activated, _) = try await client.completeCheckout(purchase)
        XCTAssertEqual(activated.licenseKey, purchase.licenseKey)
        let requests = await transport.requests
        XCTAssertEqual(requests[0].httpBody, requests[1].httpBody)
        for endpoint in ["http://checkout.stripe.com/x", "https://checkout.stripe.com.evil.test/x", "https://user@checkout.stripe.com/x"] {
            let bad = ProTransport([try result(["sessionID": "cs_test", "url": endpoint, "expiresAt": "2026-11-01T00:00:00.000Z"])])
            do { _ = try await self.client(bad).checkout(purchase); XCTFail("Untrusted checkout URL") }
            catch { XCTAssertEqual(error as? ProError, .invalidResponse) }
        }
    }

    func testBillingPortalAndCheckoutStatesAreExplicit() async throws {
        let transport = ProTransport([try result(["url": "https://billing.stripe.com/p/session/test"])])
        let portalURL = try await client(transport).portal(credentials)
        XCTAssertEqual(portalURL.host, "billing.stripe.com")
        for code in ["checkout_pending", "checkout_expired", "device_limit"] {
            let failing = ProTransport([try result(["code": code], status: 409)])
            do { _ = try await client(failing).completeCheckout(ProPurchase(deviceID: UUID().uuidString)); XCTFail() }
            catch { XCTAssertNotEqual(error as? ProError, .unavailable) }
        }
    }

    func testHostedPlanIncludesTheApprovedPriceAndAllowance() async throws {
        let transport = ProTransport([try result(["monthlyLimit": 1000, "unitAmount": 500, "currency": "USD",
            "interval": "month", "deviceLimit": 3, "checkoutEnabled": true, "billingMode": "live"])])
        let plan = try await client(transport).plan()
        XCTAssertEqual(plan.unitAmount, 500)
        XCTAssertEqual(plan.monthlyLimit, 1000)
        XCTAssertTrue(plan.checkoutEnabled)
    }
}
