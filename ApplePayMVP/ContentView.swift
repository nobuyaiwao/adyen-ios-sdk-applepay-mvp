import PassKit
import SwiftUI

struct ContentView: View {
    @StateObject private var manager = PaymentManager()

    var body: some View {
        NavigationStack {
            Form {
                Section("Payment") {
                    if let config = manager.configuration {
                        LabeledContent("Environment", value: config.environment.uppercased())
                        if config.environment == "live" {
                            Text("LIVE: this payment charges real money.")
                                .foregroundStyle(.red).bold()
                        }
                        LabeledContent("Merchant", value: config.merchantName)
                        LabeledContent("Amount", value: config.decimalAmount.decimalValue.formatted(
                            .currency(code: config.amount.currency)
                        ))
                        LabeledContent("Country", value: config.countryCode)
                    }
                    Button("Reload configuration") {
                        Task { await manager.load() }
                    }
                    .disabled(manager.isLoading || manager.isPresenting || manager.isSubmitting)
                    if manager.isLoading { ProgressView() }
                }
                Section {
                    ApplePayButton(action: manager.startPayment)
                        .frame(height: 48)
                        .disabled(!manager.canPay)
                        .opacity(manager.canPay ? 1 : 0.4)
                    if !manager.supportsApplePay {
                        Text("Apple Pay is unavailable on this device.")
                    } else if !manager.hasSupportedCard {
                        Text("Add a supported card to Wallet. Use an Apple Pay sandbox tester for test payments.")
                    }
                } footer: {
                    Text("Native PassKit → local backend → Adyen /payments. No Adyen iOS SDK.")
                }
                Section("Status") {
                    Text(manager.status).textSelection(.enabled)
                    if let result = manager.result {
                        if let pspReference = result.pspReference {
                            LabeledContent("PSP reference", value: pspReference)
                                .textSelection(.enabled)
                        }
                        if let reference = result.reference {
                            Text(reference).font(.caption).textSelection(.enabled)
                        }
                    }
                }
                Section {
                    Text("Encrypted tokens are sent once, kept in memory only, and never displayed or logged. A new authorization creates a new payment, not a retry.")
                        .font(.footnote)
                }
            }
            .navigationTitle("Apple Pay MVP")
            .task { await manager.load() }
        }
    }
}

private struct ApplePayButton: UIViewRepresentable {
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    func makeUIView(context: Context) -> PKPaymentButton {
        let button = PKPaymentButton(paymentButtonType: .buy, paymentButtonStyle: .black)
        button.addTarget(context.coordinator, action: #selector(Coordinator.pay), for: .touchUpInside)
        return button
    }

    func updateUIView(_ button: PKPaymentButton, context: Context) {
        button.isEnabled = isEnabled
        context.coordinator.action = action
    }

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    final class Coordinator: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func pay() { action() }
    }
}
