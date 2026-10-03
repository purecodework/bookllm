from dataclasses import replace
from types import SimpleNamespace
import time
from uuid import uuid4

from appstoreserverlibrary.models.Environment import Environment
from appstoreserverlibrary.models.JWSTransactionDecodedPayload import JWSTransactionDecodedPayload
from appstoreserverlibrary.models.Type import Type
from appstoreserverlibrary.signed_data_verifier import SignedDataVerifier, VerificationException
import pytest

from translation_service.ledger import ServiceError
from translation_service.purchases import ApplePurchaseVerifier


def receipt(owner, **overrides):
    values = dict(transactionId="123456789", bundleId="app.bookllm.studio", productId="app.bookllm.credits.100", purchaseDate=int(time.time() * 1000), quantity=1, type=Type.CONSUMABLE, appAccountToken=owner, environment=Environment.SANDBOX)
    values.update(overrides)
    return JWSTransactionDecodedPayload(**values)


def fake_verified_payload(payload):
    # Mock only the Apple trust boundary in these semantic validation tests.
    verifier = ApplePurchaseVerifier.__new__(ApplePurchaseVerifier)
    verifier.environment = "Sandbox"
    verifier.verifier = SimpleNamespace(verify_and_decode_signed_transaction=lambda _: payload)
    return verifier


def test_verified_purchase_semantics_and_binding():
    owner = str(uuid4())
    verifier = fake_verified_payload(receipt(owner))
    transaction = verifier.verify("signed-apple-jws", owner)
    assert transaction.transaction_key == "Sandbox:123456789"
    assert transaction.product_id == "app.bookllm.credits.100"
    with pytest.raises(ServiceError) as error:
        verifier.verify("signed-apple-jws", str(uuid4()))
    assert error.value.status == 403


@pytest.mark.parametrize("overrides", [
    {"appAccountToken": None}, {"productId": "attacker.credits.100000"}, {"type": Type.NON_CONSUMABLE},
    {"quantity": 100}, {"revocationDate": 1234}, {"transactionId": None},
    {"purchaseDate": int((time.time() + 600) * 1000)},
])
def test_invalid_verified_purchase_cannot_grant_points(overrides):
    owner = str(uuid4())
    verifier = fake_verified_payload(receipt(owner, **overrides))
    with pytest.raises(ServiceError):
        verifier.verify("signed-apple-jws", owner)


def test_official_verifier_rejects_unsigned_receipts(settings):
    verifier = ApplePurchaseVerifier(settings)
    for untrusted in ("fake-receipt", "e30.e30.", "local.storekit.transaction"):
        with pytest.raises(ServiceError) as error:
            verifier.verify(untrusted, str(uuid4()))
        assert error.value.status == 400


def test_official_notification_verifier_rejects_unsigned_payload(settings):
    verifier = ApplePurchaseVerifier(settings)
    with pytest.raises(ServiceError) as error:
        verifier.notification("e30.e30.")
    assert error.value.status == 400


def test_signed_refund_notification_verifies_both_layers():
    owner = str(uuid4())
    decoded = receipt(owner, revocationDate=1000)
    calls = []
    verifier = ApplePurchaseVerifier.__new__(ApplePurchaseVerifier)
    verifier.environment = "Sandbox"
    def notification(raw):
        calls.append(("notification", raw))
        return SimpleNamespace(notificationType=SimpleNamespace(value="REFUND"), data=SimpleNamespace(signedTransactionInfo="signed-inner"), notificationUUID="uuid-event", signedDate=1234)
    def transaction(raw):
        calls.append(("transaction", raw))
        return decoded
    verifier.verifier = SimpleNamespace(verify_and_decode_notification=notification, verify_and_decode_signed_transaction=transaction)
    assert verifier.notification("signed-outer") == ("Sandbox:123456789", True, 1234, "uuid-event")
    assert calls == [("notification", "signed-outer"), ("transaction", "signed-inner")]
