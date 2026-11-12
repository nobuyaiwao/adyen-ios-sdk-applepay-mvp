import XCTest
import PassKit
@testable import ApplePayMVP

final class PaymentTests: XCTestCase {
    private func config(currency: String = "JPY", value: Int = 1000, units: Int = 0,
                        environment: String = "test") -> PaymentConfiguration {
        PaymentConfiguration(environment: environment,
                             amount: PaymentAmount(currency: currency, value: value),
                             minorUnits: units, countryCode: "JP", merchantName: "MVP Store")
    }

    func testJPYPaymentRequestUsesExactAmountAndMerchant() throws {
        let configuration = config()
        try configuration.validate(environment: "test")
        let request = configuration.makeRequest(merchantID: "merchant.test")
        XCTAssertEqual(request.merchantIdentifier, "merchant.test")
        XCTAssertEqual(request.countryCode, "JP")
        XCTAssertEqual(request.currencyCode, "JPY")
        XCTAssertEqual(request.paymentSummaryItems.last?.amount, NSDecimalNumber(string: "1000"))
        XCTAssertEqual(request.paymentSummaryItems.last?.label, "MVP Store")
        XCTAssertEqual(request.merchantCapabilities, .threeDSecure)
        XCTAssertFalse(request.supportedNetworks.isEmpty)
    }

    func testAllSupportedCurrencyMinorUnitsAndMaximumAmount() throws {
        for (currency, units, expected) in [
            ("JPY", 0, "100000000"), ("EUR", 2, "1000000"),
            ("USD", 2, "1000000"), ("GBP", 2, "1000000")
        ] {
            let configuration = config(currency: currency, value: 100_000_000, units: units)
            try configuration.validate(environment: "test")
            XCTAssertEqual(configuration.decimalAmount, NSDecimalNumber(string: expected))
        }
        XCTAssertEqual(config(currency: "EUR", value: 1, units: 2).decimalAmount,
                       NSDecimalNumber(string: "0.01"))
    }

    func testRejectsEnvironmentMismatchAndInvalidAmount() {
        XCTAssertThrowsError(try config(environment: "live").validate(environment: "test"))
        XCTAssertThrowsError(try config(value: 0).validate(environment: "test"))
        XCTAssertThrowsError(try config(value: -1).validate(environment: "test"))
        XCTAssertThrowsError(try config(value: 100_000_001).validate(environment: "test"))
        XCTAssertThrowsError(try config(units: 2).validate(environment: "test"))
        XCTAssertThrowsError(try config(currency: "XXX").validate(environment: "test"))
    }

    func testTokenIsExactBase64OfPaymentDataNotEntireToken() throws {
        let data = Data(#"{"version":"EC_v1","data":"encrypted-test-data"}"#.utf8)
        let id = UUID()
        let submission = try PaymentSubmission(paymentData: data, amount: config().amount, requestID: id)
        XCTAssertEqual(Data(base64Encoded: submission.applePayToken), data)
        XCTAssertEqual(submission.requestId, id.uuidString.lowercased())
        let json = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(submission)
        ) as? [String: Any])
        XCTAssertEqual(Set(json.keys), Set(["applePayToken", "amount", "requestId"]))
        XCTAssertNil(json["merchantAccount"])
    }

    func testEmptyOrNonObjectTokenRejected() {
        for data in [Data(), Data("[]".utf8), Data("not-json".utf8)] {
            XCTAssertThrowsError(try PaymentSubmission(
                paymentData: data, amount: config().amount, requestID: UUID()
            ))
        }
    }

    func testOnlyAuthorisedWithoutActionIsSuccess() {
        for code in ["Refused", "Pending", "Received", "Cancelled", "Error", "RedirectShopper"] {
            XCTAssertFalse(PaymentResult(resultCode: code, pspReference: nil,
                                         reference: nil, requiresAction: nil).authorised)
        }
        XCTAssertTrue(PaymentResult(resultCode: "Authorised", pspReference: nil,
                                   reference: nil, requiresAction: nil).authorised)
        XCTAssertFalse(PaymentResult(resultCode: "Authorised", pspReference: nil,
                                    reference: nil, requiresAction: true).authorised)
    }

    func testAPIPostsTokenOnceAndParsesResult() async throws {
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [StubURLProtocol.self]
        let api = PaymentAPI(baseURL: URL(string: "https://backend.example")!,
                             session: URLSession(configuration: sessionConfiguration))
        let submission = try PaymentSubmission(
            paymentData: Data(#"{"data":"test"}"#.utf8), amount: config().amount, requestID: UUID()
        )
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/payments")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            // URLSession may convert the body to a stream before URLProtocol receives it.
            let body: Data
            if let direct = request.httpBody {
                body = direct
            } else {
                let stream = try XCTUnwrap(request.httpBodyStream)
                stream.open()
                defer { stream.close() }
                var bytes = [UInt8](repeating: 0, count: 4096)
                var collected = Data()
                while stream.hasBytesAvailable {
                    let count = stream.read(&bytes, maxLength: bytes.count)
                    if count <= 0 { break }
                    collected.append(contentsOf: bytes.prefix(count))
                }
                body = collected
            }
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(json["applePayToken"] as? String, submission.applePayToken)
            return (200, Data(#"{"resultCode":"Authorised","pspReference":"test-psp"}"#.utf8))
        }
        defer { StubURLProtocol.handler = nil }
        let result = try await api.pay(submission)
        XCTAssertTrue(result.authorised)
        XCTAssertEqual(result.pspReference, "test-psp")
    }

    func testAPISurfacesSafeBackendError() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let api = PaymentAPI(baseURL: URL(string: "https://backend.example")!,
                             session: URLSession(configuration: configuration))
        StubURLProtocol.handler = { _ in
            (502, Data(#"{"error":"Check Adyen before retrying","reference":"applepay-test"}"#.utf8))
        }
        defer { StubURLProtocol.handler = nil }
        do {
            let _: PaymentConfiguration = try await api.configuration()
            XCTFail("Expected an HTTP error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Check Adyen before retrying"))
            XCTAssertTrue(error.localizedDescription.contains("applepay-test"))
        }
    }
}

private final class StubURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let handler = try XCTUnwrap(Self.handler)
            let (status, data) = try handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                           httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}
