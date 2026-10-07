import Foundation

public struct ProCredentials: Codable, Sendable {
    public let licenseKey: String
    public let instanceID: String
    public init(licenseKey: String, instanceID: String) {
        self.licenseKey = licenseKey
        self.instanceID = instanceID
    }
}

public struct ProEntitlement: Codable, Sendable {
    public let active: Bool
    public let limit: Int
    public let used: Int
    public let resetsAt: Date
    public var remaining: Int { max(0, limit - used) }
    public let accessType: String?
    public let subscriptionStatus: String?
    public let renewsAt: Date?
    public let canManageBilling: Bool?
    /// Short support handle derived from the license hash. It authenticates nothing.
    public let account: String?
}

public struct ProPlan: Decodable, Sendable {
    public let monthlyLimit: Int
    public let unitAmount: Int
    public let currency: String
    public let interval: String
    public let deviceLimit: Int
    public let checkoutEnabled: Bool
    public let billingMode: String
    public var price: String { (Double(unitAmount) / 100).formatted(.currency(code: currency).precision(.fractionLength(0...2))) }
}

public struct ProPurchase: Codable, Sendable {
    public let licenseKey: String
    public let deviceID: String
    public var checkoutURL: URL?
    public init(licenseKey: String, deviceID: String) {
        self.licenseKey = licenseKey
        self.deviceID = deviceID
    }
    public init(deviceID: String) {
        self.deviceID = deviceID
        // SystemRandomNumberGenerator uses the platform's cryptographic generator.
        self.licenseKey = "sd_" + (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }
}

public struct ProCheckout: Decodable, Sendable {
    public let sessionID: String
    public let url: URL
    public let expiresAt: Date
}

public enum ProError: LocalizedError, Equatable {
    case unavailable, invalidResponse, invalidLicense, inactive, quota, rateLimited, pending, failedCheck
    case checkoutPending, checkoutExpired, checkoutUnavailable, deviceLimit, billingUnavailable
    case invalidCoupon, couponExpired, couponExhausted, couponRedeemed, alreadySubscribed, accountSuspended
    public var errorDescription: String? {
        switch self {
        case .unavailable: return "ShapeDesk Pro is unavailable. Try again later. Your files stay in place."
        case .invalidResponse: return "ShapeDesk Pro returned an invalid response. Your files stay in place."
        case .invalidLicense: return "This recovery key could not be activated. Check the key saved from your ShapeDesk account."
        case .inactive: return "Activate an active ShapeDesk Pro subscription to use AI Sort."
        case .quota: return "You've used this month's AI checks. More are available at your next monthly reset."
        case .rateLimited: return "Too many requests. Please wait a few minutes and try again."
        case .pending: return "This AI check is still processing. Try sorting again shortly."
        case .failedCheck: return "The AI check failed. No check was charged, and the file stays in place."
        case .checkoutPending: return "Finish your purchase in the browser, then return here to activate AI Sort."
        case .checkoutExpired: return "This checkout has expired. Start a new subscription checkout to continue."
        case .checkoutUnavailable: return "Subscriptions are not available yet. Existing access and undo still work."
        case .deviceLimit: return "This subscription has reached its Mac limit. Deactivate another Mac, then try again."
        case .billingUnavailable: return "This access does not have a paid subscription to manage."
        case .invalidCoupon: return "That coupon code isn't valid. Check it and try again."
        case .couponExpired: return "This coupon has expired."
        case .couponExhausted: return "This coupon has already been fully claimed."
        case .couponRedeemed: return "You've already redeemed this coupon on this account."
        case .alreadySubscribed: return "This account already has Pro access."
        case .accountSuspended: return "This account is suspended. Contact ShapeDesk support."
        }
    }
}

/// Only customer license credentials cross this boundary. The Jev key stays on the server.
public struct ProClient: Sendable {
    private let baseURL: URL
    private let transport: any JevTransport
    private let sleep: @Sendable () async throws -> Void

    public init(baseURL: URL) throws {
        try self.init(baseURL: baseURL, transport: URLSessionJevTransport())
    }

    #if SHAPEDESK_OWNER_PREVIEW
    /// Available only in an explicitly compiled owner preview, never in customer builds.
    public static func ownerPreview(baseURL: URL) throws -> ProClient {
        guard baseURL.scheme == "http", baseURL.host == "127.0.0.1",
              let port = baseURL.port, (1024...65535).contains(port),
              baseURL.path.isEmpty || baseURL.path == "/",
              baseURL.user == nil, baseURL.password == nil,
              baseURL.query == nil, baseURL.fragment == nil else { throw ProError.unavailable }
        return ProClient(validatedURL: baseURL, transport: URLSessionJevTransport(disableProxy: true))
    }
    #endif

    private init(validatedURL: URL, transport: any JevTransport,
                 sleep: @escaping @Sendable () async throws -> Void = { try await Task.sleep(nanoseconds: 1_000_000_000) }) {
        self.baseURL = validatedURL
        self.transport = transport
        self.sleep = sleep
    }

    init(baseURL: URL, transport: any JevTransport,
         sleep: @escaping @Sendable () async throws -> Void = { try await Task.sleep(nanoseconds: 1_000_000_000) }) throws {
        guard baseURL.scheme == "https", baseURL.host != nil,
              baseURL.user == nil, baseURL.password == nil,
              baseURL.query == nil, baseURL.fragment == nil else { throw ProError.unavailable }
        self.init(validatedURL: baseURL, transport: transport, sleep: sleep)
    }

    public func plan() async throws -> ProPlan {
        let plan: ProPlan = try await request("plans")
        guard plan.monthlyLimit > 0, plan.unitAmount > 0, plan.currency == "USD", plan.interval == "month",
              plan.deviceLimit > 0, ["live", "test"].contains(plan.billingMode) else { throw ProError.invalidResponse }
        return plan
    }

    public func checkout(_ purchase: ProPurchase) async throws -> ProCheckout {
        let result: ProCheckout = try await request("checkout", body: purchase)
        guard result.url.scheme == "https", result.url.host == "checkout.stripe.com",
              result.url.user == nil, result.url.password == nil else { throw ProError.invalidResponse }
        return result
    }

    public func completeCheckout(_ purchase: ProPurchase) async throws -> (ProCredentials, ProEntitlement) {
        struct Response: Decodable { let instanceID: String; let entitlement: ProEntitlement }
        let result: Response = try await request("checkout/complete", body: purchase)
        guard UUID(uuidString: result.instanceID) != nil else { throw ProError.invalidResponse }
        try validate(result.entitlement)
        return (ProCredentials(licenseKey: purchase.licenseKey, instanceID: result.instanceID), result.entitlement)
    }

    public func portal(_ credentials: ProCredentials) async throws -> URL {
        struct Response: Decodable { let url: URL }
        let result: Response = try await request("portal", credentials: credentials, body: [String: String]())
        guard result.url.scheme == "https", result.url.host == "billing.stripe.com",
              result.url.user == nil, result.url.password == nil else { throw ProError.invalidResponse }
        return result.url
    }

    /// Creates (or extends) a free Pro grant on the purchase's own account secret.
    /// The generated key becomes the user's recovery key, exactly like a checkout.
    public func redeem(_ purchase: ProPurchase, code: String) async throws -> (ProCredentials, ProEntitlement) {
        struct Body: Encodable { let licenseKey: String; let code: String; let deviceID: String }
        struct Response: Decodable { let instanceID: String; let entitlement: ProEntitlement }
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 64 else { throw ProError.invalidCoupon }
        let result: Response = try await request("redeem",
            body: Body(licenseKey: purchase.licenseKey, code: trimmed, deviceID: purchase.deviceID))
        guard UUID(uuidString: result.instanceID) != nil else { throw ProError.invalidResponse }
        try validate(result.entitlement)
        return (ProCredentials(licenseKey: purchase.licenseKey, instanceID: result.instanceID), result.entitlement)
    }

    public func activate(licenseKey: String, deviceID: String) async throws -> (ProCredentials, ProEntitlement) {
        struct Body: Encodable { let licenseKey: String; let deviceID: String }
        struct Response: Decodable { let instanceID: String; let entitlement: ProEntitlement }
        guard !licenseKey.isEmpty, licenseKey.count <= 256,
              !licenseKey.contains(where: { $0.isNewline }) else { throw ProError.invalidLicense }
        let result: Response = try await request("activate", body: Body(licenseKey: licenseKey, deviceID: deviceID))
        guard UUID(uuidString: result.instanceID) != nil else { throw ProError.invalidResponse }
        try validate(result.entitlement)
        return (ProCredentials(licenseKey: licenseKey, instanceID: result.instanceID), result.entitlement)
    }

    public func entitlement(_ credentials: ProCredentials) async throws -> ProEntitlement {
        let result: ProEntitlement = try await request("entitlement", credentials: credentials)
        try validate(result)
        return result
    }

    public func deactivate(_ credentials: ProCredentials) async throws {
        struct Response: Decodable { let deactivated: Bool }
        let result: Response = try await request("deactivate", credentials: credentials, body: [String: String]())
        guard result.deactivated else { throw ProError.invalidResponse }
    }

    func classify(_ metadata: FileMetadata, credentials: ProCredentials) async throws -> (FileClassification, ProEntitlement) {
        struct Body: Encodable { let requestID: String; let metadata: FileMetadata }
        struct Response: Decodable {
            let category: FileCategory; let confidence: Double; let model: String; let entitlement: ProEntitlement
        }
        // The same ID and body are reused for all transport retries, so a lost response cannot double charge.
        let body = Body(requestID: UUID().uuidString, metadata: metadata)
        let result: Response = try await request("classify", credentials: credentials, body: body, retry: true)
        guard result.confidence.isFinite, (0...1).contains(result.confidence),
              !result.model.isEmpty else { throw ProError.invalidResponse }
        try validate(result.entitlement)
        return (FileClassification(category: result.category, confidence: result.confidence, model: result.model), result.entitlement)
    }

    private func validate(_ entitlement: ProEntitlement) throws {
        guard entitlement.limit > 0, entitlement.used >= 0 else {
            throw ProError.invalidResponse
        }
    }

    private func request<T: Decodable>(_ path: String, credentials: ProCredentials? = nil) async throws -> T {
        try await request(path, credentials: credentials, body: Optional<String>.none)
    }

    private func request<T: Decodable, B: Encodable>(_ path: String, credentials: ProCredentials? = nil,
                                                    body: B?, retry: Bool = false) async throws -> T {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/\(path)"))
        request.httpMethod = body == nil ? "GET" : "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let credentials {
            guard !credentials.licenseKey.contains(where: { $0.isNewline }),
                  UUID(uuidString: credentials.instanceID) != nil else { throw ProError.inactive }
            request.setValue("Bearer \(credentials.licenseKey)", forHTTPHeaderField: "Authorization")
            request.setValue(credentials.instanceID, forHTTPHeaderField: "X-ShapeDesk-Instance")
        }
        if let body {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            request.httpBody = try encoder.encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        for attempt in 0..<(retry ? 3 : 1) {
            try Task.checkCancellation()
            let result: HTTPResult
            do { result = try await transport.send(request) }
            catch {
                if Task.isCancelled || error is CancellationError { throw CancellationError() }
                if retry, attempt < 2, let urlError = error as? URLError,
                   [.timedOut, .networkConnectionLost].contains(urlError.code) {
                    try await sleep(); continue
                }
                throw ProError.unavailable
            }
            try Task.checkCancellation()
            if result.status == 200 {
                let decoder = JSONDecoder()
                // The service emits RFC 3339 with millisecond precision.
                decoder.dateDecodingStrategy = .custom { decoder in
                    let string = try decoder.singleValueContainer().decode(String.self)
                    let formatter = ISO8601DateFormatter()
                    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                    guard let date = formatter.date(from: string) else { throw ProError.invalidResponse }
                    return date
                }
                do { return try decoder.decode(T.self, from: result.data) }
                catch { throw ProError.invalidResponse }
            }
            let code = (try? JSONDecoder().decode(Failure.self, from: result.data))?.code
            let error: ProError
            switch code {
            case "invalid_license": error = .invalidLicense
            case "inactive": error = .inactive
            case "quota_exhausted": error = .quota
            case "rate_limited": error = .rateLimited
            case "pending": error = .pending
            case "check_failed": error = .failedCheck
            case "checkout_pending": error = .checkoutPending
            case "checkout_expired": error = .checkoutExpired
            case "checkout_unavailable": error = .checkoutUnavailable
            case "already_subscribed": error = .alreadySubscribed
            case "coupon_invalid", "coupon_revoked": error = .invalidCoupon
            case "coupon_expired": error = .couponExpired
            case "coupon_exhausted": error = .couponExhausted
            case "already_redeemed": error = .couponRedeemed
            case "account_suspended": error = .accountSuspended
            case "coupon_unavailable": error = .unavailable
            case "device_limit": error = .deviceLimit
            case "billing_unavailable": error = .billingUnavailable
            default: error = .unavailable
            }
            if retry, attempt < 2, error == .pending || (code == nil && [502, 503, 504].contains(result.status)) {
                try await sleep(); continue
            }
            throw error
        }
        throw ProError.unavailable
    }

    private struct Failure: Decodable { let code: String }
}

public actor HostedClassifier: FileClassifying {
    private let client: ProClient
    private let credentials: ProCredentials
    private let onUsage: @Sendable (ProEntitlement) async -> Void
    private let onFailure: @Sendable (ProError) async -> Void
    private var terminalError: ProError?

    public init(client: ProClient, credentials: ProCredentials,
                onUsage: @escaping @Sendable (ProEntitlement) async -> Void = { _ in },
                onFailure: @escaping @Sendable (ProError) async -> Void = { _ in }) {
        self.client = client; self.credentials = credentials; self.onUsage = onUsage; self.onFailure = onFailure
    }

    public func classify(_ metadata: FileMetadata) async throws -> FileClassification {
        if let terminalError { throw terminalError }
        do {
            let (decision, usage) = try await client.classify(metadata, credentials: credentials)
            await onUsage(usage)
            return decision
        } catch let error as ProError {
            if [.quota, .inactive, .rateLimited, .unavailable].contains(error) { terminalError = error }
            await onFailure(error)
            throw error
        }
    }
}
