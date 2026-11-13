# SwiftアプリでApple Payトークンを生成する

このガイドでは、PassKitを使ってApple Payのシートを表示し、暗号化された
トークンデータを受け取るまでの流れを説明します。トークンを受け取ることは、
決済の処理や完了を意味しません。

## Apple Payの基本概念

- **Bundle IDとApp ID:** Bundle IDはXcode上でアプリを識別します。Apple
  Developerアカウントに登録する明示的なApp IDには、同じBundle IDを指定します。
  App IDでは、そのアプリが利用できる機能も管理します。
- **Merchant ID:** Apple Payで決済を受け付ける事業者を識別する、アプリとは別の
  IDです。アプリに関連付けてエンタイトルメントに含め、`PKPaymentRequest`にも
  同じ値を指定します。Bundle IDとは別の識別子です。
- **Apple Pay capabilityとエンタイトルメント:** Xcodeのアプリターゲットに
  capabilityを追加してMerchant IDを選ぶと、Xcodeが署名対象の
  `com.apple.developer.in-app-payments`エンタイトルメントにIDを追加します。
  これによりアプリがそのMerchant IDを利用できます。
- **Payment Processing Certificate:** Merchant IDに関連付ける証明書です。
  Appleは公開鍵を使って決済データを暗号化し、対応する秘密鍵は後続処理で事業者
  または決済サービス事業者がデータを復号するために使います。秘密鍵をアプリに
  含めてはいけません。
- **PassKit:** Apple Payの認証リクエストに使うAppleのフレームワークです。この
  フローでは`PKPaymentRequest`、`PKPaymentAuthorizationController`とその
  デリゲート、`PKPayment`、`PKPaymentToken`を使います。

## Apple Payを設定する

1. Apple Developerの**Certificates, Identifiers & Profiles**で、アプリの
   Bundle IDと完全に一致する明示的なApp IDを登録します。**Identifiers**で
   別途Merchant ID（**+** → **Merchant IDs**）を作成し、App IDでApple Payを
   有効にしてMerchant IDを関連付けます。これらの変更にはAccount Holderまたは
   Adminのロールが必要です。
2. **Identifiers**で**Merchant IDs**を絞り込み、対象のMerchant IDを選びます。
   **Apple Pay Payment Processing Certificate**から**Create Certificate**を
   選び、AppleのCSR手順に従います。Appleはこの証明書をApple Pay設定の一部と
   しています。アプリが使うのはMerchant IDとエンタイトルメントであり、証明書の
   秘密鍵ではありません。
3. Xcodeでアプリターゲットを選び、**Signing & Capabilities**を開いて
   **Apple Pay**を追加し、同じMerchant IDを選びます。署名チームとプロビジョ
   ニングプロファイルにこのcapabilityが含まれることを確認します。このリポジトリ
   では、`ApplePayMVP.entitlements`が`APPLE_PAY_MERCHANT_ID`の値を使います。
4. App Store Connectの**Users and Access → Sandbox → Testers**でSandbox
   テスターを作成します。Apple Pay対応の物理iPhoneでAppleのSandboxサインイン
   手順に従い、対応する地域を設定して、**Wallet → Add Card**から一覧にある
   テストカードを追加します。SandboxカードはSandboxテスト専用です。この手順に
   本番カードを使わないでください。

これらのApple Pay設定とWalletに登録された利用可能なカードがあれば、アプリは
PassKitの認証コールバックを受け取れます。PSPアカウントやサーバーが必要になるのは
トークン生成後の処理であり、このガイドの対象外です。

## 最小限のトークン生成フロー

### 1. 支払いリクエストを作る

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
            label: "サンプル店舗",
            amount: NSDecimalNumber(string: "100")
        )
    ]
    return request
}
```

各値は事業者情報と、ユーザーが認証する金額に合わせます。

- `merchantIdentifier`はApple Pay capabilityで選択し、エンタイトルメントに
  含めたMerchant IDと完全に一致させます。
- `countryCode`は事業者の2文字のISO 3166国コードです。
- `currencyCode`は取引通貨を表す3文字のISO 4217通貨コードです。
- `merchantCapabilities`は事業者が対応する決済機能を宣言します。このプロジェクト
  では`.threeDSecure`を使います。
- `supportedNetworks`には事業者が対応するネットワークを指定します。Apple Payの
  設定と一致させてください。このプロジェクトではVisa、Mastercard、American
  Express、JCB、Discoverを指定しています。
- `paymentSummaryItems`はシートに表示する金額の概要です。この例では1項目ですが、
  実際のアプリでは購入内容から表示する合計金額を作ります。

### 2. シートを表示して認証結果を受け取る

`PKPaymentAuthorizationControllerDelegate`に準拠する型でコントローラーを保持し、
デリゲートを設定してシートを表示します。

```swift
private var controller: PKPaymentAuthorizationController?

func present(_ request: PKPaymentRequest) {
    let controller = PKPaymentAuthorizationController(paymentRequest: request)
    controller.delegate = self
    self.controller = controller
    controller.present { presented in
        guard presented else {
            // シートを表示できなかった場合はエラーを表示する。
            return
        }
    }
}
```

ユーザーがシートを承認すると、PassKitは`PKPayment`を渡して
`paymentAuthorizationController(_:didAuthorizePayment:handler:)`を呼び出します。
トークンにはこのコールバックでアクセスできます。

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

    // 次の処理にはpaymentDataをメモリ内で渡す。
    // この例はトークン取得のみで、決済処理はしていない。
    completion(PKPaymentAuthorizationResult(status: .failure, errors: nil))
}

func paymentAuthorizationControllerDidFinish(
    _ controller: PKPaymentAuthorizationController
) {
    controller.dismiss(completion: nil)
    self.controller = nil
}
```

`PKPaymentToken.paymentData`は、UTF-8でシリアライズされたJSON辞書を含む`Data`
です。Base64エンコードは必要な場合に完全な`Data`全体へ行う、転送用の表現です。
エンコードしても復号はされません。`PKPaymentToken`全体やJSON内の一部フィールド
だけをエンコードしないでください。

転送先が文字列を必要とする場合は、完全なデータをエンコードします。

```swift
let base64ForTransport = paymentData.base64EncodedString()
```

デリゲートのcompletion handlerは必ず1回呼び出します。トークン取得だけの例では、
決済処理をしていないため失敗を返します。これは通常の購入に必要なPassKitの要件
ではありません。実際のアプリではトークンを受け取っただけで購入成功とせず、決済
フローの結果を返してください。

## このリポジトリでの実装

- `PaymentConfiguration.makeRequest(merchantID:)`が設定値から
  `PKPaymentRequest`を作成し、`PaymentManager.startPayment()`がシートを表示します。
- `PaymentManager.paymentAuthorizationController(_:didAuthorizePayment:handler:)`
  が`PKPayment`を受け取り、`payment.token.paymentData`を読み出します。
- 通常の送信フローでは、`PaymentSubmission`が空でないJSONであることを確認し、
  データ全体をBase64エンコードします。
- Test schemeでは`DEBUG`が定義されています。DEBUGのcapture経路は固定額のJPY 100
  を使い、バックエンドには送信せず、決済を処理していないためシートに失敗を返し
  ます。非DEBUGの経路はリポジトリのバックエンド処理に進み、Live schemeでは本番
  設定を使う場合があります。

現在のDEBUG経路はトークン全体をXcodeコンソールに出力します。これはこの
リポジトリ固有の動作であり、トークンのログ出力を禁止するリポジトリのルールに
反します。ログはIDEの診断情報、CI出力、バグ報告などに残る可能性があります。
Sandboxデータも機密情報として扱ってください。厳重に管理されたSandbox環境は
漏えい範囲を狭めますが、トークンの生ログを安全にするわけではありません。この
リポジトリのルールに従い、出力を削除するか、機密情報を含まないメタデータに
置き換えてください。トークンはメモリ内で扱い、本番カードのトークンを実験に
使わないでください。

## テストとトラブルシューティング

- AppleのSandbox手順は、対応デバイスとWalletのテストカードを使ったテストを
  説明しています。Apple PayはデバイスのSecure Elementを使用します。Simulator
  では物理デバイスのWalletおよびSecure Elementの経路を検証できないため、
  PSPで復号可能かを確認する場合は物理iPhoneを使います。AppleはSimulatorで生成
  されたすべてのトークンが復号不能だとは明記していません。Simulatorの結果は、
  復号可能なトークンの証明として扱わないでください。
- シートが表示されない場合は、Merchant ID、エンタイトルメント、App IDとBundle
  IDの一致、署名プロファイル、デバイス対応状況、Walletカード、対応ネットワークを
  確認します。シートをキャンセルした場合、認証コールバックは呼び出されません。
- このリポジトリで「Token captured. No payment submitted.」と表示された場合、
  DEBUGコールバックが空でないデータを受け取ったという意味です。決済成功を意味
  しません。
- XCTestは合成データとモックHTTPを使います。リクエスト生成やエンコードは確認
  できますが、実際のWalletトークン生成や証明書の検証はできません。

## Appleの公式ドキュメント

- [App IDを登録する](https://developer.apple.com/help/account/manage-identifiers/register-an-app-id)
- [Apple Payを設定する](https://developer.apple.com/help/account/capabilities/configure-apple-pay/)
- [XcodeでApple Payサポートを設定する](https://developer.apple.com/documentation/xcode/configuring-apple-pay-support)
- [`PKPaymentRequest`](https://developer.apple.com/documentation/passkit/pkpaymentrequest)
- [`PKPaymentAuthorizationController`](https://developer.apple.com/documentation/passkit/pkpaymentauthorizationcontroller)
- [`PKPaymentAuthorizationControllerDelegate`](https://developer.apple.com/documentation/passkit/pkpaymentauthorizationcontrollerdelegate)
- [`PKPaymentToken.paymentData`](https://developer.apple.com/documentation/passkit/pkpaymenttoken/paymentdata)
- [Apple Pay Sandboxテスト](https://developer.apple.com/apple-pay/sandbox-testing/)
