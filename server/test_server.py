import base64
from dataclasses import replace
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock, patch
import uuid

import requests

from config import Config
from server import create_app


class ServerTests(unittest.TestCase):
    def setUp(self):
        self.config = Config(environment="test", api_key="test-secret", merchant_account="TestMerchant")
        self.app = create_app(self.config)
        self.client = self.app.test_client()
        self.token_data = {
            "version": "EC_v1",
            "data": "synthetic-encrypted-data",
            "signature": "synthetic-signature",
            "header": {
                "ephemeralPublicKey": "synthetic-key",
                "publicKeyHash": "synthetic-hash",
                "transactionId": "synthetic-id",
            },
        }
        self.body = {
            "applePayToken": self.encode(self.token_data),
            "amount": {"currency": "JPY", "value": 1000},
            "requestId": str(uuid.uuid4()),
        }
        self.post = patch("server.requests.post").start()
        self.addCleanup(patch.stopall)
        self.post.return_value = self.response(200, {"resultCode": "Authorised", "pspReference": "TEST-PSP"})

    @staticmethod
    def encode(value):
        return base64.b64encode(json.dumps(value).encode()).decode()

    @staticmethod
    def response(status, body):
        return Mock(status_code=status, json=Mock(return_value=body))

    def test_config_and_health_do_not_expose_secrets(self):
        self.assertEqual(self.client.get("/health").json["environment"], "test")
        response = self.client.get("/config")
        self.assertEqual(response.json, {
            "environment": "test", "amount": self.body["amount"], "minorUnits": 0,
            "countryCode": "JP", "merchantName": "Apple Pay MVP",
        })
        self.assertEqual(response.headers["Cache-Control"], "no-store")
        self.assertNotIn("test-secret", response.text)
        self.post.assert_not_called()

    def test_exact_adyen_payload_and_base64_pass_through(self):
        response = self.client.post("/payments", json=self.body)
        self.assertEqual(response.status_code, 200)
        args, kwargs = self.post.call_args
        self.assertEqual(args, ("https://checkout-test.adyen.com/v72/payments",))
        self.assertEqual(kwargs["json"], {
            "merchantAccount": "TestMerchant",
            "reference": "applepay-" + self.body["requestId"],
            "amount": {"currency": "JPY", "value": 1000},
            "countryCode": "JP",
            "channel": "iOS",
            "returnUrl": "applepaymvp://payment",
            "paymentMethod": {"type": "applepay", "applePayToken": self.body["applePayToken"]},
        })
        self.assertEqual(kwargs["headers"]["X-API-Key"], "test-secret")
        self.assertEqual(kwargs["headers"]["Idempotency-Key"], self.body["requestId"])
        self.assertEqual(kwargs["timeout"], (3, 18))
        self.assertFalse(kwargs["allow_redirects"])
        self.post.assert_called_once()
        self.assertEqual(response.json["resultCode"], "Authorised")

    def test_repeat_request_reuses_reference_and_idempotency_key(self):
        self.client.post("/payments", json=self.body)
        self.client.post("/payments", json=self.body)
        first, second = self.post.call_args_list
        self.assertEqual(first.kwargs["json"], second.kwargs["json"])
        self.assertEqual(first.kwargs["headers"], second.kwargs["headers"])

    def test_new_authorization_has_new_reference(self):
        self.client.post("/payments", json=self.body)
        self.body["requestId"] = str(uuid.uuid4())
        self.client.post("/payments", json=self.body)
        first, second = self.post.call_args_list
        self.assertNotEqual(first.kwargs["headers"]["Idempotency-Key"],
                            second.kwargs["headers"]["Idempotency-Key"])

    def test_refused_and_pending_are_not_relabelled_success(self):
        for code in ("Refused", "Pending", "Received"):
            with self.subTest(code=code):
                self.post.return_value = self.response(200, {"resultCode": code})
                self.assertEqual(self.client.post("/payments", json=self.body).json["resultCode"], code)

    def test_action_is_flagged_but_not_forwarded(self):
        self.post.return_value = self.response(200, {
            "resultCode": "RedirectShopper", "action": {"url": "https://example.com/private"},
        })
        result = self.client.post("/payments", json=self.body).json
        self.assertTrue(result["requiresAction"])
        self.assertNotIn("action", result)

    def test_amount_is_server_controlled(self):
        for amount in (None, {}, {"currency": "EUR", "value": 1000},
                       {"currency": "JPY", "value": 999},
                       {"currency": "JPY", "value": 1000.0},
                       {"currency": "JPY", "value": True}):
            with self.subTest(amount=amount):
                body = dict(self.body, amount=amount)
                self.assertEqual(self.client.post("/payments", json=body).status_code, 409)
        self.post.assert_not_called()

    def test_all_supported_currency_boundaries(self):
        for currency, units in (("JPY", 0), ("EUR", 2), ("USD", 2), ("GBP", 2)):
            for value in (1, 100_000_000):
                with self.subTest(currency=currency, value=value):
                    client = create_app(replace(self.config, currency=currency, amount=value)).test_client()
                    self.assertEqual(client.get("/config").json["minorUnits"], units)
                    body = dict(self.body, amount={"currency": currency, "value": value})
                    self.assertEqual(client.post("/payments", json=body).status_code, 200)
                    self.assertEqual(self.post.call_args.kwargs["json"]["amount"], body["amount"])

    def test_invalid_tokens_rejected_before_adyen(self):
        for token in ("", "not-base64!", self.encode([]), self.encode({}),
                      self.encode({"paymentData": self.token_data}), 123, None,
                      "A" * 64_001):
            with self.subTest(token_type=type(token).__name__):
                self.assertEqual(self.client.post("/payments", json=dict(
                    self.body, applePayToken=token
                )).status_code, 400)
        self.post.assert_not_called()

    def test_missing_token_fields_rejected(self):
        for key in self.token_data:
            token_data = dict(self.token_data)
            del token_data[key]
            response = self.client.post("/payments", json=dict(
                self.body, applePayToken=self.encode(token_data)
            ))
            self.assertEqual(response.status_code, 400)
        self.post.assert_not_called()

    def test_bad_json_types_and_content_type(self):
        for body in ([], None, "text", 1):
            response = self.client.post("/payments", data=json.dumps(body), content_type="application/json")
            self.assertEqual(response.status_code, 400)
        self.assertEqual(self.client.post("/payments", data="{", content_type="application/json").status_code, 400)
        self.assertEqual(self.client.post("/payments", data="text").status_code, 400)
        self.post.assert_not_called()

    def test_invalid_request_id(self):
        for value in (None, 42, [], {}, "bad", "A" * 36):
            response = self.client.post("/payments", json=dict(self.body, requestId=value))
            self.assertEqual(response.status_code, 400)
        self.post.assert_not_called()

    def test_request_size_is_bounded(self):
        response = self.client.post("/payments", data="x" * 96_001, content_type="application/json")
        self.assertEqual(response.status_code, 413)
        self.post.assert_not_called()

    def test_network_failure_does_not_retry_or_leak(self):
        for error in (requests.Timeout("test-secret"), requests.ConnectionError(self.body["applePayToken"])):
            self.post.reset_mock()
            self.post.side_effect = error
            response = self.client.post("/payments", json=self.body)
            self.assertEqual(response.status_code, 502)
            self.assertIn("outcome unknown", response.json["error"])
            self.assertEqual(response.json["reference"], "applepay-" + self.body["requestId"])
            self.assertNotIn("test-secret", response.text)
            self.assertNotIn(self.body["applePayToken"], response.text)
            self.post.assert_called_once()

    def test_upstream_errors_are_sanitized(self):
        for status in (302, 401, 422, 500):
            self.post.return_value = self.response(status, {"message": self.body["applePayToken"]})
            response = self.client.post("/payments", json=self.body)
            self.assertEqual(response.status_code, 502)
            self.assertNotIn(self.body["applePayToken"], response.text)

    def test_non_json_or_unexpected_upstream_response(self):
        for value in (None, [], {}, {"resultCode": 123}):
            self.post.return_value = self.response(200, value)
            self.assertEqual(self.client.post("/payments", json=self.body).status_code, 502)
        self.post.return_value.json.side_effect = ValueError("HTML")
        self.assertEqual(self.client.post("/payments", json=self.body).status_code, 502)

    def test_success_response_only_contains_safe_fields(self):
        self.post.return_value = self.response(200, {
            "resultCode": "Authorised", "pspReference": "TEST-PSP",
            "paymentMethod": {"applePayToken": self.body["applePayToken"]},
            "additionalData": {"secret": "test-secret"},
        })
        response = self.client.post("/payments", json=self.body)
        self.assertEqual(set(response.json), {"resultCode", "pspReference", "reference"})

    def test_live_url_and_validation(self):
        live = replace(self.config, environment="live", live_endpoint_prefix="prefix")
        self.assertEqual(live.checkout_base_url,
                         "https://prefix-checkout-live.adyenpayments.com/checkout/v72")
        client = create_app(live).test_client()
        self.assertEqual(client.get("/config").json["environment"], "live")
        client.post("/payments", json=self.body)
        self.assertEqual(self.post.call_args.args[0], live.checkout_base_url + "/payments")
        for changes in ({"environment": "invalid"}, {"environment": "live"},
                        {"api_version": "https://bad"}, {"amount": 0}, {"amount": True},
                        {"amount": 100_000_001}, {"currency": "XXX"},
                        {"country_code": "JPN"}, {"merchant_name": ""}, {"api_key": ""}):
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                replace(self.config, **changes)

    def test_environment_file_loading(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / ".env.test"
            path.write_text("ADYEN_API_KEY=file-key\nADYEN_MERCHANT_ACCOUNT=FileMerchant\nPAYMENT_AMOUNT=42\n")
            with patch.dict("os.environ", {"ADYEN_CONFIG": str(path)}, clear=True):
                config = Config.from_environment()
            self.assertEqual(config.amount, 42)
            self.assertEqual(config.merchant_account, "FileMerchant")
            with patch.dict("os.environ", {
                "ADYEN_CONFIG": str(path), "ADYEN_API_KEY": "override",
            }, clear=True):
                self.assertEqual(Config.from_environment().api_key, "override")


if __name__ == "__main__":
    unittest.main()
