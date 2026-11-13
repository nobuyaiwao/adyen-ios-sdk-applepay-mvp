import PassKit
import SwiftUI

@MainActor
final class PaymentManager: NSObject, ObservableObject, PKPaymentAuthorizationControllerDelegate {
    @Published private(set) var configuration: PaymentConfiguration?
    @Published private(set) var status = "Load the backend configuration to begin."
    @Published private(set) var isLoading = false
    @Published private(set) var isPresenting = false
    @Published private(set) var isSubmitting = false
    @Published private(set) var result: PaymentResult?

    private var appConfiguration: AppConfiguration?
    private var api: PaymentAPI?
    private var controller: PKPaymentAuthorizationController?
    private var submitted = false
    private var requestID: UUID?

    var supportsApplePay: Bool { PKPaymentAuthorizationController.canMakePayments() }
    var hasSupportedCard: Bool {
        PKPaymentAuthorizationController.canMakePayments(usingNetworks: PaymentConfiguration.networks)
    }
    var canPay: Bool {
        configuration != nil && !isLoading && !isPresenting && !isSubmitting && supportsApplePay && hasSupportedCard
    }

    func load() async {
        guard !isLoading, !isPresenting, !isSubmitting else { return }
        isLoading = true
        configuration = nil
        result = nil
        defer { isLoading = false }
        do {
            let settings = try AppConfiguration.load()
            appConfiguration = settings

            #if DEBUG
            let config = PaymentConfiguration.testConfiguration
            try config.validate(environment: settings.environment)
            configuration = config
            api = nil
            status = "Ready. Apple Pay Token Capture Mode."
            #else
            let client = PaymentAPI(baseURL: settings.backendURL)
            let config = try await client.configuration()
            try config.validate(environment: settings.environment)
            api = client
            configuration = config
            status = "Ready. Authorize Apple Pay to submit one /payments request."
            #endif

        } catch {
            status = error.localizedDescription
        }
    }

    func startPayment() {
        guard canPay, let configuration, let appConfiguration else { return }
        submitted = false
        requestID = UUID()
        result = nil
        isPresenting = true
        status = "Waiting for Apple Pay authorization."
        let controller = PKPaymentAuthorizationController(
            paymentRequest: configuration.makeRequest(merchantID: appConfiguration.merchantID)
        )
        self.controller = controller
        controller.delegate = self
        controller.present { [weak self] presented in
            Task { @MainActor in
                guard let self, !presented else { return }
                self.controller = nil
                self.isPresenting = false
                self.status = "Could not present Apple Pay. Check signing, Merchant ID and Wallet setup."
            }
        }
    }

    func paymentAuthorizationController(
        _ controller: PKPaymentAuthorizationController,
        didAuthorizePayment payment: PKPayment,
        handler completion: @escaping (PKPaymentAuthorizationResult) -> Void
    ) {
        guard !submitted,
              configuration != nil,
              requestID != nil else {
            completion(PKPaymentAuthorizationResult(
                status: .failure,
                errors: [PaymentError.message("Start a new payment attempt.")]
            ))
            return
        }
    
        submitted = true
        isSubmitting = true
    
        #if DEBUG
        let tokenData = payment.token.paymentData
    
        guard !tokenData.isEmpty else {
            status = "Apple Pay returned empty token data."
            isSubmitting = false
            completion(PKPaymentAuthorizationResult(
                status: .failure,
                errors: [PaymentError.message("Empty Apple Pay Token.")]
            ))
            return
        }
    
        print("========== APPLE PAY TOKEN BEGIN ==========")
        print(tokenData.base64EncodedString())
        print("========== APPLE PAY TOKEN END ==========")
    
        status = "Token captured. No payment submitted."
        isSubmitting = false
    
        completion(PKPaymentAuthorizationResult(
            status: .failure,
            errors: [PaymentError.message("Token captured for testing only.")]
        ))
    
        #else
        guard let api,
              let configuration,
              let requestID else {
            isSubmitting = false
            completion(PKPaymentAuthorizationResult(
                status: .failure,
                errors: [PaymentError.message("Payment configuration unavailable.")]
            ))
            return
        }
    
        status = "Token received. Submitting to Adyen…"
    
        Task {
            defer { isSubmitting = false }
    
            do {
                let submission = try PaymentSubmission(
                    paymentData: payment.token.paymentData,
                    amount: configuration.amount,
                    requestID: requestID
                )
    
                let response = try await api.pay(submission)
                result = response
    
                status = response.requiresAction == true
                    ? "Additional action required, unsupported by this MVP. Check Adyen."
                    : "Adyen result: \(response.resultCode)"
    
                completion(PKPaymentAuthorizationResult(
                    status: response.authorised ? .success : .failure,
                    errors: response.authorised ? nil : [PaymentError.message(status)]
                ))
            } catch {
                status = "\(error.localizedDescription)\nIf submitted, the outcome may be unknown. Check Adyen before trying again.\nReference: applepay-\(requestID.uuidString.lowercased())"
    
                completion(PKPaymentAuthorizationResult(
                    status: .failure,
                    errors: [
                        PaymentError.message("Payment could not be confirmed. Check the app and Adyen.")
                    ]
                ))
            }
        }
        #endif
    }

    func paymentAuthorizationControllerDidFinish(_ controller: PKPaymentAuthorizationController) {
        controller.dismiss { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.controller = nil
                self.isPresenting = false
                if !self.submitted {
                    self.status = "Cancelled. No payment was submitted."
                }
            }
        }
    }
}
