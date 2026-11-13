import Foundation
import PassKit

struct AppConfiguration {
    let merchantID: String
    let backendURL: URL
    let environment: String

    static func load(bundle: Bundle = .main) throws -> AppConfiguration {
        guard let merchantID = bundle.object(forInfoDictionaryKey: "ApplePayMerchantID") as? String,
              merchantID.hasPrefix("merchant."),
              !merchantID.contains("example"),
              let value = bundle.object(forInfoDictionaryKey: "BackendURL") as? String,
              let url = URL(string: value),
              let host = url.host,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              let environment = bundle.object(forInfoDictionaryKey: "AppEnvironment") as? String,
              ["test", "live"].contains(environment),
              url.scheme == "https" || (environment == "test" && url.scheme == "http"
                  && (host == "localhost" || host == "127.0.0.1" || host.hasSuffix(".local")))
        else {
            throw PaymentError.message("Configure Merchant ID and Backend URL in Config/Secrets.<environment>.xcconfig.")
        }
        return AppConfiguration(merchantID: merchantID, backendURL: url, environment: environment)
    }
}

struct PaymentAmount: Codable, Equatable {
    let currency: String
    let value: Int
}

struct PaymentConfiguration: Decodable {
    let environment: String
    let amount: PaymentAmount
    let minorUnits: Int
    let countryCode: String
    let merchantName: String

    func validate(environment expected: String) throws {
        let units = ["JPY": 0, "EUR": 2, "USD": 2, "GBP": 2]
        guard environment == expected else {
            throw PaymentError.message("App/backend environment mismatch. Check the selected scheme and ADYEN_CONFIG.")
        }
        guard units[amount.currency] == minorUnits,
              amount.value > 0, amount.value <= 100_000_000,
              countryCode.range(of: "^[A-Z]{2}$", options: .regularExpression) != nil,
              !merchantName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PaymentError.message("Backend payment configuration is invalid.")
        }
    }

    var decimalAmount: NSDecimalNumber {
        NSDecimalNumber(mantissa: UInt64(amount.value), exponent: Int16(-minorUnits), isNegative: false)
    }

    func makeRequest(merchantID: String) -> PKPaymentRequest {
        let request = PKPaymentRequest()
        request.merchantIdentifier = merchantID
        request.countryCode = countryCode
        request.currencyCode = amount.currency
        request.merchantCapabilities = .threeDSecure
        request.supportedNetworks = Self.networks
        request.paymentSummaryItems = [
            PKPaymentSummaryItem(label: merchantName, amount: decimalAmount)
        ]
        return request
    }

    static let networks: [PKPaymentNetwork] = [.visa, .masterCard, .amex, .JCB, .discover]

    #if DEBUG
    static let testConfiguration = PaymentConfiguration(
        environment: "test",
        amount: PaymentAmount(currency: "JPY", value: 100),
        minorUnits: 0,
        countryCode: "JP",
        merchantName: "Apple Pay Token Test"
    )
    #endif

}

struct PaymentSubmission: Encodable {
    let applePayToken: String
    let amount: PaymentAmount
    let requestId: String

    init(paymentData: Data, amount: PaymentAmount, requestID: UUID) throws {
        guard !paymentData.isEmpty,
              let data = try? JSONSerialization.jsonObject(with: paymentData),
              data is [String: Any] else {
            throw PaymentError.message("Apple Pay returned no usable paymentData.")
        }
        // paymentData is already JSON bytes. Encode it, not the entire PKPaymentToken.
        applePayToken = paymentData.base64EncodedString()
        self.amount = amount
        requestId = requestID.uuidString.lowercased()
    }
}

struct PaymentResult: Decodable {
    let resultCode: String
    let pspReference: String?
    let reference: String?
    let requiresAction: Bool?

    var authorised: Bool { resultCode == "Authorised" && requiresAction != true }
}

enum PaymentError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let text): return text
        }
    }
}

private struct BackendErrorResponse: Decodable {
    let error: String
    let reference: String?
}

struct PaymentAPI {
    let baseURL: URL
    private let session: URLSession

    init(baseURL: URL, session: URLSession? = nil) {
        self.baseURL = baseURL
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.timeoutIntervalForRequest = 25
            configuration.timeoutIntervalForResource = 25
            self.session = URLSession(configuration: configuration)
        }
    }

    func configuration() async throws -> PaymentConfiguration {
        try await send(URLRequest(url: baseURL.appendingPathComponent("config")))
    }

    func pay(_ submission: PaymentSubmission) async throws -> PaymentResult {
        var request = URLRequest(url: baseURL.appendingPathComponent("payments"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(submission)
        return try await send(request)
    }

    private func send<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw PaymentError.message("No HTTP response from backend.")
        }
        guard (200..<300).contains(response.statusCode) else {
            if let error = try? JSONDecoder().decode(BackendErrorResponse.self, from: data) {
                throw PaymentError.message(error.error + (error.reference.map { "\nReference: \($0)" } ?? ""))
            }
            throw PaymentError.message("Backend returned HTTP \(response.statusCode).")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
