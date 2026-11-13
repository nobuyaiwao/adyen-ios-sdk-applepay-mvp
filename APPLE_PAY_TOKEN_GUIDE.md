# Apple Pay Token Generation in a Swift App

This guide shows how PassKit presents Apple Pay and returns encrypted token
data. Receiving that data is not the same as processing or completing a payment.

## Key Apple Pay concepts

- **Bundle ID and App ID:** The Bundle ID identifies your app in Xcode. An
  explicit App ID in the Apple Developer account is registered with that same
  Bundle ID and controls which capabilities the app can use.
- **Merchant ID:** A separate Apple Developer identifier for the business
  accepting Apple Pay. It must be selected for the app and supplied in the
  `PKPaymentRequest`; it is not the app's Bundle ID.
- **Apple Pay capability and entitlement:** Add the capability to the app
  target in Xcode and select the Merchant ID. Xcode adds it to the signed
  `com.apple.developer.in-app-payments` entitlement, which allows the app to
  use that Merchant ID.
- **Payment Processing Certificate:** This certificate is associated with the
  Merchant ID. Apple uses its public key to encrypt payment data; the
  corresponding private key is used later by the merchant or payment processor
  to decrypt it. The private key does not belong in the app.
- **PassKit:** Apple's framework for requesting Apple Pay authorization. This
  flow uses `PKPaymentRequest`, `PKPaymentAuthorizationController`, its
  delegate, `PKPayment`, and `PKPaymentToken`.

## Configure Apple Pay

1. In **Certificates, Identifiers & Profiles**, register an explicit App ID
   using the app's exact Bundle ID. Under **Identifiers**, create a separate
   Merchant ID (**+** → **Merchant IDs**), then enable Apple Pay for the App ID
   and associate the Merchant ID. These account changes require an Account
   Holder or Admin role.
2. Under **Identifiers**, filter for **Merchant IDs** and select yours. In
   **Apple Pay Payment Processing Certificate**, choose **Create Certificate**
   and follow Apple's CSR instructions. Apple lists this certificate as part
   of Apple Pay setup; the app uses the Merchant ID and entitlement, not the
   certificate's private key.
3. In Xcode, select the app target, open **Signing & Capabilities**, add
   **Apple Pay**, and select the same Merchant ID. Confirm the signing team
   and provisioning profile include the capability. In this repository,
   `ApplePayMVP.entitlements` takes the value from `APPLE_PAY_MERCHANT_ID`.
4. In App Store Connect, create a sandbox tester under **Users and Access →
   Sandbox → Testers**. On a physical Apple Pay-capable iPhone, follow Apple's
   sandbox sign-in steps, set a supported device region, and add a listed test
   card in **Wallet → Add Card**. Sandbox cards are for sandbox testing only;
   never use a production card for this exercise.

These Apple Pay setup steps and an eligible Wallet card let the app receive
PassKit's authorization callback. A PSP account or server is only needed for
what happens after token generation, which is outside this guide's scope.

## Minimal token generation flow

### 1. Construct a payment request

```swift
import PassKit

func makePaymentRequest(merchantID: String) -> PKPaymentRequest {
    let request = PKPaymentRequest()
    request.merchantIdentifier = merchantID
    request.countryCode = "JP"
    request.currencyCode = "JPY"
    request.merchantCapabilities = .threeDSecure
    request.supportedNetworks = [.visa, .masterCard, .amex, .JCB, .discover]
    request.paymentSummaryItems = [
        PKPaymentSummaryItem(
            label: "Example Store",
            amount: NSDecimalNumber(string: "100")
        )
    ]
    return request
}
```

The values should describe the merchant and the amount the customer is
authorizing:

- `merchantIdentifier` must exactly match the Merchant ID selected in the
  Apple Pay capability and included in the entitlement.
- `countryCode` is the merchant's two-letter ISO 3166 country code.
- `currencyCode` is the transaction's three-letter ISO 4217 currency code.
- `merchantCapabilities` declares the processing capabilities supported by
  the merchant; this project uses `.threeDSecure`.
- `supportedNetworks` lists networks the merchant supports. Keep it consistent
  with the merchant's Apple Pay setup; this project lists Visa, Mastercard,
  American Express, JCB, and Discover.
- `paymentSummaryItems` describes the amount shown in the sheet. The example
  has one item; real apps should build the displayed total from the purchase.

### 2. Present the sheet and receive authorization

In a type that conforms to `PKPaymentAuthorizationControllerDelegate`, retain
the controller, set its delegate, and present it:

```swift
private var controller: PKPaymentAuthorizationController?

func present(_ request: PKPaymentRequest) {
    let controller = PKPaymentAuthorizationController(paymentRequest: request)
    controller.delegate = self
    self.controller = controller
    controller.present { presented in
        guard presented else {
            // Show an error if the sheet could not be presented.
            return
        }
    }
}
```

After the customer authorizes, PassKit calls
`paymentAuthorizationController(_:didAuthorizePayment:handler:)` with a
`PKPayment`. That callback is when the app can access the token:

```swift
func paymentAuthorizationController(
    _ controller: PKPaymentAuthorizationController,
    didAuthorizePayment payment: PKPayment,
    handler completion: @escaping (PKPaymentAuthorizationResult) -> Void
) {
    let paymentData = payment.token.paymentData
    guard !paymentData.isEmpty else {
        completion(PKPaymentAuthorizationResult(status: .failure, errors: nil))
        return
    }

    // Keep paymentData in memory for the next step.
    // This token-only example did not process a payment.
    completion(PKPaymentAuthorizationResult(status: .failure, errors: nil))
}

func paymentAuthorizationControllerDidFinish(
    _ controller: PKPaymentAuthorizationController
) {
    controller.dismiss(completion: nil)
    self.controller = nil
}
```

`PKPaymentToken.paymentData` is a `Data` value containing a UTF-8 serialized
JSON dictionary. Base64-encoding the complete `Data` is optional and only
changes its transport representation; it does not decrypt the payload. Do not
encode the whole `PKPaymentToken` object or just one JSON field.

If a transport expects a string, encode the complete data:

```swift
let base64ForTransport = paymentData.base64EncodedString()
```

The delegate must call its completion handler once. A token-only demonstration
returns failure because no payment was processed; that is not a PassKit
requirement for normal purchases. A real app should report the result of its
payment flow, not treat token receipt alone as a completed payment.

## How this repository implements the flow

- `PaymentConfiguration.makeRequest(merchantID:)` builds the configured
  `PKPaymentRequest`. `PaymentManager.startPayment()` presents it.
- `PaymentManager.paymentAuthorizationController(_:didAuthorizePayment:handler:)`
  receives the `PKPayment` and reads `payment.token.paymentData`.
- `PaymentSubmission` validates non-empty JSON and Base64-encodes the complete
  data on the normal submission path.
- The Test scheme defines `DEBUG`: its capture branch uses a fixed JPY 100
  request, skips the backend, and returns failure because no payment was
  processed. The non-DEBUG path continues to the repository's backend flow;
  the Live scheme can use live configuration.

The current DEBUG branch prints the full token to Xcode's console. This
repository-specific behavior conflicts with its rule against token logging.
Logs can persist in IDE diagnostics, CI output, or bug reports. A tightly
controlled sandbox-only environment reduces exposure but does not make raw
token logging safe. This repository's rule prohibits it; remove the print or
replace it with redacted metadata. Keep token data in memory and never use a
production-card token for experiments.

## Testing and troubleshooting

- Apple describes sandbox testing with supported devices and Wallet test
  cards. Apple Pay uses the device's Secure Element; Simulator cannot verify
  the physical device's Wallet and Secure Element path. Use a physical iPhone
  for PSP-decryption checks. Apple does not explicitly state that every
  Simulator-generated token is invalid, so treat Simulator results as
  non-authoritative rather than proof of a decryptable token.
- A cancelled sheet does not invoke the authorization callback. If the sheet
  won't appear, check the Merchant ID, entitlement, App ID/Bundle ID match,
  signing profile, device support, Wallet card, and supported networks.
- In this repository, “Token captured. No payment submitted.” means the DEBUG
  callback received non-empty data. It does not mean a payment succeeded.
- XCTest uses synthetic data and mocked HTTP. It verifies request construction
  and encoding, but cannot produce a real Wallet token or validate a certificate.

## Apple documentation

- [Register an App ID](https://developer.apple.com/help/account/manage-identifiers/register-an-app-id)
- [Configure Apple Pay](https://developer.apple.com/help/account/capabilities/configure-apple-pay/)
- [Configuring Apple Pay support in Xcode](https://developer.apple.com/documentation/xcode/configuring-apple-pay-support)
- [`PKPaymentRequest`](https://developer.apple.com/documentation/passkit/pkpaymentrequest)
- [`PKPaymentAuthorizationController`](https://developer.apple.com/documentation/passkit/pkpaymentauthorizationcontroller)
- [`PKPaymentAuthorizationControllerDelegate`](https://developer.apple.com/documentation/passkit/pkpaymentauthorizationcontrollerdelegate)
- [`PKPaymentToken.paymentData`](https://developer.apple.com/documentation/passkit/pkpaymenttoken/paymentdata)
- [Apple Pay Sandbox Testing](https://developer.apple.com/apple-pay/sandbox-testing/)
