# Apple Pay MVP

A small SwiftUI iOS app for manually testing Apple Pay with your own Apple
Merchant ID and Payment Processing Certificate. Uses native PassKit, **no Adyen
iOS SDK**. 

This is an integration test harness, not a production checkout or a replacement
for a real-device Apple Pay test. Automated tests use synthetic tokens and
mocked Adyen responses; they cannot verify your certificate or charge a card.

## Flow

1. App loads the amount, currency, country, merchant display name and environment
   from `GET /config`.
2. PassKit presents Apple Pay using your Merchant ID and the configured amount.
3. After authorization, the app base64-encodes the **entire JSON bytes of
   `payment.token.paymentData`**, not `PKPaymentToken` and not its `data` field alone.
4. App sends `{applePayToken, amount, requestId}` to the local backend's
   `POST /payments`.
5. Backend checks the amount and token envelope, then calls Adyen Checkout v72:

   ```json
   {
     "merchantAccount": "YOUR_MERCHANT_ACCOUNT",
     "reference": "applepay-<requestId>",
     "amount": {"currency": "JPY", "value": 1000},
     "countryCode": "JP",
     "channel": "iOS",
     "returnUrl": "applepaymvp://payment",
     "paymentMethod": {
       "type": "applepay",
       "applePayToken": "<base64 paymentData>"
     }
   }
   ```

6. The app shows `resultCode`, PSP reference and merchant reference.
   Only `Authorised` without an additional action completes Apple Pay as success.

The token stays encrypted for Adyen to decrypt. The certificate/private key is
**not** installed in the app. No Adyen client key is needed.

## Requirements

- Xcode 26+ and iOS 17+.
- Python 3.11+ (use `python3.13` or `python3.11` if your `python3` is older).
- Apple Developer account, signing team and an Apple Pay-capable physical device.
- Adyen test account with Apple Pay enabled.

## 1. Configure your Merchant ID and certificate

You do these steps yourself:

1. Register your app's bundle ID and enable Apple Pay in Apple Developer.
2. Register or select your Apple Merchant ID.
3. Follow [Adyen's own-certificate setup][certificate]. For Adyen-managed token
   decryption, generate the CSR through Adyen, create the **Apple Pay Payment
   Processing Certificate** under your Merchant ID in Apple Developer using that
   CSR, and complete the certificate setup in Adyen.
   A certificate made from an unrelated private key will not let Adyen decrypt
   these tokens. Do not send private keys to the app or put them in this repository.
4. Associate the Merchant ID with your app's Apple Pay capability and provisioning
   profile. The entitlement uses the same `APPLE_PAY_MERCHANT_ID` build setting
   as the PassKit request.
5. Enable Apple Pay on the relevant Adyen merchant account. Configure test and
   live separately, as applicable.

This is a native in-app flow. It does **not** need web domain validation, a
Merchant Identity Certificate, or `/applePay/sessions`.

## 2. Start the test backend

From the repository root:

```sh
cd server
python3.13 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
cp .env.test.example .env.test
```

Edit `.env.test` and set `ADYEN_API_KEY` and `ADYEN_MERCHANT_ACCOUNT`.
Then start:

```sh
ADYEN_CONFIG=.env.test python server.py
```

It listens on `http://127.0.0.1:8080` with the debugger disabled. Environment
file paths are relative to `server/`, unless absolute. Existing environment
variables take precedence over the file, matching the reference backend.
`GET /health` checks availability; neither `/health` nor `/config` calls Adyen.

Default payment: **JPY 1,000 / JP**. Change `PAYMENT_AMOUNT` (integer minor units),
`PAYMENT_CURRENCY`, `PAYMENT_COUNTRY_CODE`, and `PAYMENT_MERCHANT_NAME` in the
environment file and restart the backend. Tap **Reload configuration** in the app.
Supported currencies: JPY (0 decimals), EUR/USD/GBP (2 decimals). The backend
rejects a stale or altered amount, rather than submitting a different amount
from the Apple Pay sheet.

## 3. Configure and run the app

```sh
cp ApplePayMVP/Config/Secrets.test.xcconfig.example \
   ApplePayMVP/Config/Secrets.test.xcconfig
open ApplePayMVP.xcodeproj
```

Edit `Secrets.test.xcconfig`:

```text
DEVELOPMENT_TEAM = YOUR_TEAM_ID
PRODUCT_BUNDLE_IDENTIFIER = com.yourcompany.ApplePayMVP
APPLE_PAY_MERCHANT_ID = merchant.com.yourcompany
BACKEND_URL = http:/$()/localhost:8080
```

`$()` preserves `//` in an xcconfig URL. The app intentionally rejects the
placeholder Merchant ID until you configure it. Select **ApplePayMVP-Test**,
select your device, check **Signing & Capabilities**, and run.

### Simulator versus physical device

- Simulator: `localhost:8080` points to the Mac. You can build/run unit tests
  and check the app, but use a real device for certificate and payment validation.
- Physical device: `localhost` points to the phone, **not** your Mac. For a
  private test on your trusted LAN, stop `python server.py`, then start the
  backend with:

  ```sh
  flask --app server:create_app run --host 0.0.0.0 --port 8080 --no-debugger
  ```

  Set `BACKEND_URL` to `http:/$()/Your-Mac.local:8080` (replace with the Mac's
  local hostname), use the same Wi-Fi, and allow local network access on iOS
  and incoming access in the Mac firewall. The app allows HTTP only for
  test-mode loopback or `.local` hosts; ATS uses `NSAllowsLocalNetworking`, not a
  global insecure-transport exception.

  **This exposes an unauthenticated payment endpoint on your LAN. Use test
  credentials only, keep the network private, and stop the server after testing.**
  Prefer a trusted HTTPS backend for anything beyond this local experiment.

### Exercise the real flow

1. Set up an [Apple Pay sandbox tester and supported sandbox card][sandbox] on a
   physical device using Apple's instructions.
2. Run the test backend and Test scheme with matching configuration.
3. Confirm the displayed currency/amount, tap the Apple Pay button, and authorize.
4. Verify `Authorised` and the PSP reference in the app and Adyen test Customer Area.
5. Also cancel the sheet before authorizing: the app should say no payment was
   submitted. Test a refusal where supported by your sandbox setup.

Apple Pay availability and eligible Wallet cards are checked before enabling
the button. The networks are Visa, Mastercard, Amex, JCB and Discover. Adjust
`PaymentConfiguration.networks` to match your merchant's enabled networks.

## Live configuration (optional, real money)

Copy `.env.live.example` to `.env.live` in `server/` and
`Secrets.live.xcconfig.example` to `Secrets.live.xcconfig` in the app's `Config/`
directory. Set live credentials, merchant, endpoint prefix, certificate setup
and a trusted HTTPS backend URL. Run the backend with `ADYEN_CONFIG=.env.live`
and select **ApplePayMVP-Live**. The app rejects an environment mismatch and
shows a prominent live warning.

Do not expose this Flask development server publicly or use its unauthenticated
endpoint as a production backend. Before any remote/live deployment, add
authentication, authorization, TLS termination, rate limits and durable order
state. Live authorization can charge real money. This repository does not run
any live payments automatically.

## Automated checks

Backend, without credentials or network payment calls:

```sh
cd server
source .venv/bin/activate
python -m unittest -v
```

iOS tests, without signing or merchant credentials (replace the destination if
needed with an installed simulator):

```sh
xcodebuild test \
  -project ApplePayMVP.xcodeproj \
  -scheme ApplePayMVP-Test \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.1' \
  -derivedDataPath build/DerivedData \
  CODE_SIGNING_ALLOWED=NO
```

Tests cover exact paymentData base64 encoding, PassKit request amounts, currency
minor units, environment mismatch, HTTP request/response handling, the Adyen
payload, idempotency key mapping, malformed tokens, stale amounts, refused/pending
results, additional actions and sanitized upstream failures.

## Limitations and safety

- The backend validates the encrypted token's JSON envelope, not its signature.
  Adyen performs cryptographic validation and decryption. Only EC_v1 tokens are
  supported by this MVP.
- Tokens and API keys are not printed, displayed or written to disk. Avoid
  network-body logging or sharing debugger dumps containing token data.
- Each authorization gets a UUID used as Adyen's idempotency key and merchant
  reference. Duplicate HTTP submissions with that same ID use the same key.
  The app does not automatically retry or offer token replay. A new authorization
  creates a **new** payment.
- A timeout or lost response can occur after Adyen processes the request. Check
  the displayed merchant reference in Customer Area before starting another
  authorization. A failed Apple Pay sheet alone is not proof of no charge.
- Additional actions/redirects, `/payments/details`, webhooks, capture, refunds,
  stored tokens and production order reconciliation are out of scope.
  The `returnUrl` is a required API field, not an implemented redirect handler.
- `.env` files, local xcconfig files, certificates, keys, and build output are
  ignored by Git. No existing demo credentials have been copied.

[certificate]: https://docs.adyen.com/payment-methods/apple-pay/apple-pay-certificate/
[sandbox]: https://developer.apple.com/apple-pay/sandbox-testing/
