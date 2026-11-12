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
            let client = PaymentAPI(baseURL: settings.backendURL)
            let config = try await client.configuration()
            try config.validate(environment: settings.environment)
            appConfiguration = settings
            api = client
            configuration = config
            status = "Ready. Authorize Apple Pay to submit one /payments request."
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
        guard !submitted, let configuration, let api, let requestID else {
            completion(PKPaymentAuthorizationResult(status: .failure, errors: [
                PaymentError.message("Start a new payment attempt.")
            ]))
            return
        }
        submitted = true
        isSubmitting = true
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
                completion(PKPaymentAuthorizationResult(status: .failure, errors: [
                    PaymentError.message("Payment could not be confirmed. Check the app and Adyen.")
                ]))
            }
        }
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
