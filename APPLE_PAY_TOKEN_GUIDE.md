# Generating an Apple Pay Token in a Swift App

This guide follows the native PassKit flow in this repository. PassKit, not the
app, creates the Apple Pay payment token after the customer authorizes the sheet.
The app receives the token data and can pass it to a payment processor. It does
not decrypt or construct the token itself.

## Prerequisites

- Register an app identifier and Apple Merchant ID in the Apple Developer
  account. Enable Apple Pay for the app identifier and associate the Merchant ID.
- Configure the Apple Pay capability, signing team, provisioning profile, and
  `APPLE_PAY_MERCHANT_ID` build setting. The entitlement and PassKit request
  must use the same Merchant ID.
- For a real authorization test, use a physical Apple Pay-capable iPhone with
  an eligible sandbox tester and card. A simulator is useful for building and
  UI checks, but does not validate the full device payment flow.
- Keep the app and backend in the same environment. The Test scheme uses
  `Secrets.test.xcconfig`; the Live scheme can submit real payments.

## How the token is produced

The app first creates a `PKPaymentRequest` with the merchant ID, country,
currency, amount, merchant display name, and supported networks. In this
project, `PaymentConfiguration.makeRequest(merchantID:)` builds that request.

`PaymentManager.startPayment()` presents it with a `PKPaymentAuthorizationController`:

```swift
let request = configuration.makeRequest(merchantID: appConfiguration.merchantID)
let controller = PKPaymentAuthorizationController(paymentRequest: request)
controller.delegate = self
controller.present { presented in
    guard presented else {
        // Report that the Apple Pay sheet could not be presented.
        return
    }
}
```

After the customer authorizes the sheet, PassKit calls
`paymentAuthorizationController(_:didAuthorizePayment:handler:)` with a
`PKPayment`. This delegate callback is where the app receives the payment data:

```swift
func paymentAuthorizationController(
    _ controller: PKPaymentAuthorizationController,
    didAuthorizePayment payment: PKPayment,
    handler completion: @escaping (PKPaymentAuthorizationResult) -> Void
) {
    let paymentData = payment.token.paymentData
    // Validate and process paymentData, then call completion exactly once.
}
```

`paymentData` is a `Data` value containing the encrypted Apple Pay token
payload. It is not the entire `PKPaymentToken` object, and the app must not
extract only a field such as `data`.

## Validate and encode the payment data

Before sending it, ensure the data is non-empty and parses as a JSON object.
`PaymentSubmission` performs this validation and Base64-encodes the complete
`paymentData` byte sequence:

```swift
let submission = try PaymentSubmission(
    paymentData: payment.token.paymentData,
    amount: configuration.amount,
    requestID: requestID
)
```

The request ID is created once for the authorization attempt. The encoded
`applePayToken` is sent with the matching amount and request ID. Base64 is only
an encoding for transport; it does not decrypt or protect the token.

## Submit through the backend

In the normal payment path, the app passes the submission to
`PaymentAPI.pay(_:)`, which sends JSON to the backend's `POST /payments`
endpoint. The backend uses its Adyen API key to call Checkout. Keep that API key
on the backend, never in the iOS app.

Amounts must match the amount authorized in the Apple Pay sheet and the
backend's configured amount. The current DEBUG capture configuration displays
JPY 100, while the backend defaults to JPY 1,000. Align these settings before
submitting a captured authorization.

## DEBUG capture mode in this repository

The current Test scheme defines `DEBUG`, so it uses a capture-only branch in
`PaymentManager`: it uses the fixed test amount, skips `/config` and `/payments`,
and completes the Apple Pay sheet as a failure because no payment was submitted.
The non-DEBUG branch performs the backend request. Do not select the Live scheme
just to reach that branch; it can send real payments.

The current DEBUG branch also prints the full Base64 token to the Xcode console.
That is not a safe token-handling pattern and conflicts with this repository's
security guidance. Do not share console output, copy real tokens into shell
commands, or save them to files. Prefer keeping token data in memory and sending
it directly to an approved test backend. For backend tests that do not need an
Apple Pay device token, use the repository's synthetic-token tests.

## Authorization result and troubleshooting

The app should report success to PassKit only after the backend confirms an
`Authorised` result with no unsupported additional action. A cancelled sheet
does not submit a payment. In DEBUG capture mode, the failure result is
intentional and does not mean Adyen declined a payment, because that mode makes
no backend request.

If `paymentData` is empty, verify that you are testing on a physical device with
Apple Pay configured and an eligible card. If the backend cannot be reached
from an iPhone, remember that `localhost` refers to the phone; use an
IT-approved reachable test endpoint. Check the backend and app environments
before retrying any authorization.

## Automated tests

The XCTest suite uses synthetic payment data and mocked HTTP responses. It
checks request construction, validation, and Base64 encoding, but it does not
generate a real Apple Pay token or validate Merchant ID certificates.
