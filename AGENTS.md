# Repository Guidelines

## Project Structure

- `ApplePayMVP/` contains the SwiftUI iOS app, PassKit/payment logic, entitlements, and `Config/` build settings. Keep environment-specific secrets in ignored local `Secrets.*.xcconfig` files; commit only the `.example` templates.
- `ApplePayMVPTests/` contains the XCTest suite.
- `server/` contains the Flask backend, its configuration, requirements, and `unittest` suite.
- `ApplePayMVP.xcodeproj/` defines the app and the shared Test/Live schemes. `build/` is generated output and is ignored.

## Build, Test, and Run

- Install backend dependencies with `cd server && pip install -r requirements.txt`.
- Run backend tests with `cd server && python -m unittest -v`. They use mocked Adyen responses and synthetic tokens.
- Run iOS tests with:

  ```sh
  xcodebuild test -project ApplePayMVP.xcodeproj \
    -scheme ApplePayMVP-Test \
    -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.1' \
    -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO
  ```

- For local manual testing, configure the ignored `.env.test` and `Secrets.test.xcconfig` files as described in `README.md`, then run `ADYEN_CONFIG=.env.test python server.py` from `server/` and launch the Test scheme in Xcode.

## Style and Testing

Use four spaces for indentation. Follow existing Swift naming: `UpperCamelCase` for types and `lowerCamelCase` for members. Use `snake_case` for Python functions and variables. There is no configured formatter or linter. Name Swift tests `test...` methods in `PaymentTests`; name backend tests `test_...` methods in `ServerTests`. Add or update tests for behavior changes, keeping network/payment calls mocked.

## Commits and Pull Requests

This checkout has no Git history available, so its commit convention cannot be confirmed. Use a concise imperative subject, such as `Validate payment request amount`. Pull requests should explain behavior and configuration changes, list test commands and results, and include screenshots for UI changes. Call out any manual device-only checks.

## Security

Never commit API keys, merchant credentials, certificates, private keys, real payment tokens, or local secret configuration files. Do not log payment request bodies or token data. Use test credentials only for manual integration checks; live payments can charge real money.
