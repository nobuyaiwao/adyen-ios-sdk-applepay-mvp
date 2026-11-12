from dataclasses import dataclass
import os
from pathlib import Path
import re

from dotenv import load_dotenv


# Deliberately small set of currencies, with the same minor units in Apple/Adyen.
CURRENCY_MINOR_UNITS = {"JPY": 0, "EUR": 2, "USD": 2, "GBP": 2}


@dataclass(frozen=True)
class Config:
    environment: str
    api_key: str
    merchant_account: str
    api_version: str = "v72"
    live_endpoint_prefix: str = ""
    currency: str = "JPY"
    amount: int = 1000
    country_code: str = "JP"
    merchant_name: str = "Apple Pay MVP"

    def __post_init__(self):
        if self.environment not in {"test", "live"}:
            raise ValueError("ADYEN_ENVIRONMENT must be test or live")
        if not self.api_key.strip() or not self.merchant_account.strip():
            raise ValueError("Adyen API key and merchant account are required")
        if not re.fullmatch(r"v[0-9]+", self.api_version):
            raise ValueError("ADYEN_API_VERSION must look like v72")
        if self.environment == "live" and not re.fullmatch(
            r"[A-Za-z0-9-]+", self.live_endpoint_prefix
        ):
            raise ValueError("A valid ADYEN_LIVE_ENDPOINT_PREFIX is required for live")
        if self.currency not in CURRENCY_MINOR_UNITS:
            raise ValueError("PAYMENT_CURRENCY must be JPY, EUR, USD or GBP")
        if type(self.amount) is not int or not 0 < self.amount <= 100_000_000:
            raise ValueError("PAYMENT_AMOUNT must be 1..100000000 in minor units")
        if not re.fullmatch(r"[A-Z]{2}", self.country_code):
            raise ValueError("PAYMENT_COUNTRY_CODE must be a two-letter country code")
        if not self.merchant_name.strip():
            raise ValueError("PAYMENT_MERCHANT_NAME is required")

    @property
    def checkout_base_url(self):
        if self.environment == "test":
            return f"https://checkout-test.adyen.com/{self.api_version}"
        return (
            f"https://{self.live_endpoint_prefix}-checkout-live.adyenpayments.com"
            f"/checkout/{self.api_version}"
        )

    @property
    def payment_amount(self):
        return {"currency": self.currency, "value": self.amount}

    @classmethod
    def from_environment(cls):
        config_file = Path(os.getenv("ADYEN_CONFIG", ".env.test"))
        if not config_file.is_absolute():
            config_file = Path(__file__).parent / config_file
        load_dotenv(config_file, override=False)
        return cls(
            environment=os.getenv("ADYEN_ENVIRONMENT", "test").lower(),
            api_key=os.environ["ADYEN_API_KEY"],
            merchant_account=os.environ["ADYEN_MERCHANT_ACCOUNT"],
            api_version=os.getenv("ADYEN_API_VERSION", "v72"),
            live_endpoint_prefix=os.getenv("ADYEN_LIVE_ENDPOINT_PREFIX", ""),
            currency=os.getenv("PAYMENT_CURRENCY", "JPY").upper(),
            amount=int(os.getenv("PAYMENT_AMOUNT", "1000")),
            country_code=os.getenv("PAYMENT_COUNTRY_CODE", "JP").upper(),
            merchant_name=os.getenv("PAYMENT_MERCHANT_NAME", "Apple Pay MVP"),
        )
