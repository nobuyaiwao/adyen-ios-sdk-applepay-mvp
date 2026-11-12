import base64
import binascii
import json
import uuid

import requests
from flask import Flask, jsonify, request
from werkzeug.exceptions import BadRequest, RequestEntityTooLarge, UnsupportedMediaType

from config import Config, CURRENCY_MINOR_UNITS


def valid_token(token):
    if not isinstance(token, str) or not token or len(token) > 64_000:
        return False
    try:
        data = json.loads(base64.b64decode(token, validate=True))
    except (ValueError, UnicodeDecodeError, binascii.Error):
        return False
    return (
        isinstance(data, dict)
        and data.get("version") == "EC_v1"
        and all(isinstance(data.get(key), str) and data[key] for key in ("data", "signature"))
        and isinstance(data.get("header"), dict)
        and all(
            isinstance(data["header"].get(key), str) and data["header"][key]
            for key in ("ephemeralPublicKey", "publicKeyHash", "transactionId")
        )
    )


def create_app(config=None):
    config = config or Config.from_environment()
    app = Flask(__name__)
    app.config["MAX_CONTENT_LENGTH"] = 96_000

    @app.after_request
    def no_cache(response):
        response.headers["Cache-Control"] = "no-store"
        return response

    @app.errorhandler(BadRequest)
    @app.errorhandler(UnsupportedMediaType)
    def invalid_json(_error):
        return jsonify(error="Send a valid JSON object"), 400

    @app.errorhandler(RequestEntityTooLarge)
    def payload_too_large(_error):
        return jsonify(error="Request is too large"), 413

    @app.get("/health")
    def health():
        return jsonify(status="ok", environment=config.environment)

    @app.get("/config")
    def payment_config():
        return jsonify(
            environment=config.environment,
            amount=config.payment_amount,
            minorUnits=CURRENCY_MINOR_UNITS[config.currency],
            countryCode=config.country_code,
            merchantName=config.merchant_name,
        )

    @app.post("/payments")
    def payments():
        body = request.get_json()
        if not isinstance(body, dict):
            return jsonify(error="Send a valid JSON object"), 400
        token = body.get("applePayToken")
        if not valid_token(token):
            return jsonify(error="Invalid base64 Apple Pay paymentData"), 400
        amount = body.get("amount")
        if (
            not isinstance(amount, dict)
            or type(amount.get("value")) is not int
            or amount != config.payment_amount
        ):
            return jsonify(error="Amount changed. Reload payment configuration"), 409
        request_id = body.get("requestId")
        try:
            if str(uuid.UUID(request_id)) != request_id:
                raise ValueError()
        except (ValueError, TypeError, AttributeError):
            return jsonify(error="requestId must be a canonical UUID"), 400

        payload = {
            "merchantAccount": config.merchant_account,
            "reference": f"applepay-{request_id}",
            "amount": config.payment_amount,
            "countryCode": config.country_code,
            "channel": "iOS",
            "returnUrl": "applepaymvp://payment",
            "paymentMethod": {"type": "applepay", "applePayToken": token},
        }
        try:
            response = requests.post(
                f"{config.checkout_base_url}/payments",
                json=payload,
                headers={
                    "X-API-Key": config.api_key,
                    "Content-Type": "application/json",
                    "Idempotency-Key": request_id,
                },
                timeout=(3, 18),
                allow_redirects=False,
            )
        except requests.RequestException:
            # Do not log the exception: it may carry request data or credentials.
            return jsonify(
                error="Payment outcome unknown. Check Adyen before starting another payment.",
                reference=payload["reference"],
            ), 502
        try:
            result = response.json()
        except ValueError:
            result = None
        if not 200 <= response.status_code < 300 or not isinstance(result, dict):
            # Never forward raw upstream errors or token-bearing responses.
            return jsonify(
                error="Adyen API error. Check the payment in Customer Area.",
                statusCode=response.status_code,
                reference=payload["reference"],
            ), 502
        if not isinstance(result.get("resultCode"), str):
            return jsonify(
                error="Unexpected Adyen response. Check the payment in Customer Area.",
                reference=payload["reference"],
            ), 502
        safe_result = {
            key: result[key]
            for key in ("resultCode", "pspReference")
            if isinstance(result.get(key), str)
        }
        safe_result["reference"] = payload["reference"]
        # This MVP does not implement redirect / additional-action handling.
        if result.get("action") is not None:
            safe_result["requiresAction"] = True
        return jsonify(safe_result)

    return app


if __name__ == "__main__":
    app = create_app()
    print("Apple Pay MVP backend, loopback only. No tokens or API keys are logged.")
    app.run(host="127.0.0.1", port=8080, debug=False)
