import hashlib
import time
import pytest

from translation_service.config import Settings
from translation_service.ledger import Ledger


@pytest.fixture
def settings(tmp_path):
    return Settings(database_path=str(tmp_path / "ledger.sqlite3"), session_secret="unit-test-secret-" * 4, apple_bundle_id="app.bookllm.studio", apple_app_id=12345678, apple_environment="Sandbox", apple_root_paths=(), deepseek_api_key="unit-test-not-a-real-secret")


@pytest.fixture
def ledger(settings):
    return Ledger(settings.database_path)


def create_account(ledger, subject="subject-1", amount=100):
    digest = hashlib.sha256(subject.encode()).hexdigest()
    account = ledger.login(subject, "app.bookllm.studio", digest, "nonce-" + digest, time.time() + 600)
    if amount:
        product = "app.bookllm.credits.1000" if amount == 1000 else "app.bookllm.credits.100"
        account = ledger.redeem(account["accountID"], "Sandbox:test-" + subject, product, digest)
    return account["accountID"]
