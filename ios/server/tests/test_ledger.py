from concurrent.futures import ThreadPoolExecutor
import hashlib
import time

import pytest

from translation_service.ledger import Ledger, ServiceError, content_hash, source_cost
from conftest import create_account


def test_unicode_character_cost_and_content_hash():
    assert source_cost("中" * 1000) == 1
    assert source_cost("🌱" * 1001) == 2
    assert source_cost("a" * 2001) == 3
    assert content_hash("translate", {"b": 2, "a": 1}) == content_hash("translate", {"a": 1, "b": 2})
    assert content_hash("translate", {"a": 1}) != content_hash("glossary", {"a": 1})


def test_purchase_redemption_is_atomic_and_replay_safe(ledger):
    owner = create_account(ledger, amount=0)
    def purchase(_):
        return ledger.redeem(owner, "Sandbox:unique-tx", "app.bookllm.credits.100", "signed")
    with ThreadPoolExecutor(max_workers=12) as executor:
        values = list(executor.map(purchase, range(40)))
    assert all(value["points"] == 100 for value in values)
    assert ledger.account(owner)["points"] == 100
    with ledger.connection() as db:
        assert db.execute("SELECT COUNT(*) FROM credit_events").fetchone()[0] == 1
    another = create_account(ledger, subject="subject-2", amount=0)
    with pytest.raises(ServiceError) as error:
        ledger.redeem(another, "Sandbox:unique-tx", "app.bookllm.credits.100", "different-serialization")
    assert error.value.status == 403


def test_duplicate_request_delivers_cached_result_without_charge(ledger):
    owner = create_account(ledger)
    assert ledger.reserve(owner, "req", "translate", "hash", 3) is None
    with pytest.raises(ServiceError) as error:
        ledger.reserve(owner, "req", "translate", "hash", 3)
    assert error.value.status == 409
    ledger.dispatch(owner, "req")
    ledger.complete(owner, "req", {"text": "译文"})
    assert ledger.reserve(owner, "req", "translate", "hash", 3) == {"text": "译文"}
    assert ledger.account(owner)["points"] == 97
    with pytest.raises(ServiceError) as changed:
        ledger.reserve(owner, "req", "translate", "other-hash", 3)
    assert changed.value.status == 409


def test_idempotency_is_account_scoped(ledger):
    first = create_account(ledger)
    second = create_account(ledger, subject="other")
    ledger.reserve(first, "req", "translate", "h1", 1)
    ledger.reserve(second, "req", "translate", "h2", 2)
    assert ledger.request_status(first, "req")["points"] == 1
    assert ledger.request_status(second, "req")["points"] == 2
    with pytest.raises(ServiceError) as error:
        ledger.request_status(second, "only-first")
    assert error.value.status == 404


def test_concurrent_duplicate_only_reserves_once(ledger):
    owner = create_account(ledger)
    def reserve(_):
        try:
            ledger.reserve(owner, "req", "translate", "hash", 10)
            return "reserved"
        except ServiceError as error:
            return error.status
    with ThreadPoolExecutor(max_workers=12) as executor:
        values = list(executor.map(reserve, range(50)))
    assert values.count("reserved") == 1
    assert values.count(409) == 49
    assert ledger.account(owner)["points"] == 90


def test_concurrent_spending_never_overdraws(settings):
    ledger = Ledger(settings.database_path, per_account_concurrency=50, global_concurrency=50)
    owner = create_account(ledger)
    def reserve(i):
        try:
            ledger.reserve(owner, f"req-{i}", "translate", f"hash-{i}", 7)
            return "reserved"
        except ServiceError as error:
            return error.status
    with ThreadPoolExecutor(max_workers=12) as executor:
        values = list(executor.map(reserve, range(40)))
    assert values.count("reserved") == 14
    assert values.count(402) == 26
    assert ledger.account(owner)["points"] == 2


def test_concurrency_limit_does_not_reserve_or_debit(ledger):
    owner = create_account(ledger)
    for i in range(4):
        ledger.reserve(owner, str(i), "translate", str(i), 1)
    with pytest.raises(ServiceError) as error:
        ledger.reserve(owner, "fifth", "translate", "fifth", 1)
    assert error.value.status == 429
    assert error.value.retry_after == 2
    assert ledger.account(owner)["points"] == 96


def test_global_limit_applies_across_ledger_instances(settings):
    first = Ledger(settings.database_path, per_account_concurrency=2, global_concurrency=2)
    second = Ledger(settings.database_path, per_account_concurrency=2, global_concurrency=2)
    owner1 = create_account(first)
    owner2 = create_account(first, subject="other")
    first.reserve(owner1, "1", "translate", "h", 1)
    second.reserve(owner2, "2", "translate", "h", 1)
    with pytest.raises(ServiceError) as error:
        second.reserve(owner2, "3", "translate", "h", 1)
    assert error.value.status == 429


def test_definite_refund_is_once_and_retry_charges_once(ledger):
    owner = create_account(ledger)
    ledger.reserve(owner, "req", "translate", "h", 3)
    ledger.dispatch(owner, "req")
    assert ledger.refund(owner, "req")
    assert not ledger.refund(owner, "req")
    assert ledger.account(owner)["points"] == 100
    ledger.reserve(owner, "req", "translate", "h", 3)
    assert ledger.account(owner)["points"] == 97
    with ledger.connection() as db:
        net = db.execute("SELECT SUM(delta) FROM credit_events WHERE account_id=?", (owner,)).fetchone()[0]
    assert net == ledger.account(owner)["points"]


def test_ambiguous_requests_preserve_charge_and_require_explicit_reconciliation(ledger):
    owner = create_account(ledger)
    ledger.reserve(owner, "req", "translate", "h", 3)
    ledger.dispatch(owner, "req")
    ledger.uncertain(owner, "req")
    assert not ledger.refund(owner, "req")
    assert ledger.account(owner)["points"] == 97
    with pytest.raises(ServiceError) as error:
        ledger.reserve(owner, "req", "translate", "h", 3)
    assert error.value.status == 409
    assert ledger.refund(owner, "req", allow_uncertain=True)
    assert ledger.account(owner)["points"] == 100


def test_login_identity_and_nonce_replay_rejected(ledger):
    first = ledger.login("subject", "bundle", "fingerprint", "nonce-hash", time.time() + 600)
    for fingerprint, nonce in (("fingerprint", "different"), ("different", "nonce-hash")):
        with pytest.raises(ServiceError) as error:
            ledger.login("subject", "bundle", fingerprint, nonce, time.time() + 600)
        assert error.value.status == 401
    second = ledger.login("subject", "bundle", "new-fingerprint", "new-nonce", time.time() + 600)
    assert first["accountID"] == second["accountID"]


def test_refund_notification_is_replay_safe_and_blocks_old_receipt(ledger):
    owner = create_account(ledger)
    key = "Sandbox:test-subject-1"
    assert ledger.purchase_notification(key, True, 1000, "refund-1")
    assert ledger.account(owner)["points"] == 0
    assert not ledger.purchase_notification(key, True, 1000, "refund-1")
    assert ledger.account(owner)["points"] == 0
    assert ledger.redeem(owner, key, "app.bookllm.credits.100", "old-jws")["points"] == 0
    ledger.purchase_notification("Sandbox:pre-refunded", True, 1000, "refund-2")
    with pytest.raises(ServiceError) as error:
        ledger.redeem(owner, "Sandbox:pre-refunded", "app.bookllm.credits.100", "old-jws")
    assert error.value.status == 400


def test_refund_after_spending_creates_debt_and_reversal_repays_once(ledger):
    owner = create_account(ledger)
    ledger.reserve(owner, "spent", "translate", "h", 30)
    ledger.dispatch(owner, "spent")
    ledger.complete(owner, "spent", {"text": "translated"})
    key = "Sandbox:test-subject-1"
    ledger.purchase_notification(key, True, 1000, "refund-1")
    assert ledger.account(owner)["points"] == 0
    assert ledger.account(owner)["creditDebt"] == 30
    with pytest.raises(ServiceError) as error:
        ledger.reserve(owner, "new", "translate", "h", 1)
    assert error.value.status == 402
    ledger.purchase_notification(key, False, 2000, "reversal-1")
    assert ledger.account(owner)["points"] == 70
    assert ledger.account(owner)["creditDebt"] == 0
    assert not ledger.purchase_notification(key, True, 1500, "out-of-order-refund")
    assert ledger.account(owner)["points"] == 70


def test_new_purchase_repays_refunded_spent_credits_first(ledger):
    owner = create_account(ledger)
    ledger.reserve(owner, "spent", "translate", "h", 20)
    ledger.dispatch(owner, "spent")
    ledger.complete(owner, "spent", {"text": "translated"})
    ledger.purchase_notification("Sandbox:test-subject-1", True, 1000, "refund-1")
    ledger.redeem(owner, "Sandbox:new-purchase", "app.bookllm.credits.100", "new-jws")
    assert ledger.account(owner)["points"] == 80
    assert ledger.account(owner)["creditDebt"] == 0


def test_lifetime_unlock_revocation_and_reversal(ledger):
    owner = create_account(ledger, amount=0)
    ledger.redeem(owner, "Sandbox:lifetime", "app.bookllm.byok.lifetime", "jws")
    assert ledger.account(owner)["ownAPIUnlocked"]
    ledger.purchase_notification("Sandbox:lifetime", True, 1000, "revoke-lifetime")
    assert not ledger.account(owner)["ownAPIUnlocked"]
    ledger.purchase_notification("Sandbox:lifetime", False, 2000, "reverse-lifetime")
    assert ledger.account(owner)["ownAPIUnlocked"]
