import hashlib
import json
import time
from uuid import uuid4

from cryptography.hazmat.primitives.asymmetric import rsa
import httpx
import jwt
import pytest

from translation_service.auth import APPLE_ISSUER, AppleIdentityVerifier, Sessions
from translation_service.ledger import ServiceError


@pytest.fixture
def apple_signer():
    private = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    jwk = json.loads(jwt.algorithms.RSAAlgorithm.to_jwk(private.public_key()))
    jwk.update({"kid": "unit-test-key", "alg": "RS256"})
    return private, jwk


async def verifier_fixture(apple_signer, settings):
    private, jwk = apple_signer
    transport = httpx.MockTransport(lambda request: httpx.Response(200, json={"keys": [jwk]}))
    client = httpx.AsyncClient(transport=transport)
    return private, client, AppleIdentityVerifier(client, settings.apple_bundle_id)


def make_token(private, settings, nonce, **overrides):
    now = int(time.time())
    claims = {"iss": APPLE_ISSUER, "aud": settings.apple_bundle_id, "sub": "apple-subject", "iat": now, "exp": now + 300, "nonce": hashlib.sha256(nonce.encode()).hexdigest()}
    claims.update(overrides)
    return jwt.encode(claims, private, algorithm="RS256", headers={"kid": "unit-test-key"})


@pytest.mark.asyncio
async def test_apple_identity_signature_and_nonce(apple_signer, settings):
    private, client, verifier = await verifier_fixture(apple_signer, settings)
    async with client:
        nonce = "random-unit-test-nonce-123"
        token = make_token(private, settings, nonce)
        assert (await verifier.verify(token, nonce))["sub"] == "apple-subject"
        with pytest.raises(ServiceError) as error:
            await verifier.verify(token, "a-different-unit-test-nonce")
        assert error.value.status == 401


@pytest.mark.asyncio
@pytest.mark.parametrize("override", [{"aud": "attacker.bundle"}, {"iss": "https://attacker.example"}, {"exp": 0}, {"iat": 0}, {"sub": ""}])
async def test_apple_identity_rejects_untrusted_claims(apple_signer, settings, override):
    private, client, verifier = await verifier_fixture(apple_signer, settings)
    async with client:
        nonce = "random-unit-test-nonce-123"
        with pytest.raises(ServiceError) as error:
            await verifier.verify(make_token(private, settings, nonce, **override), nonce)
        assert error.value.status == 401


@pytest.mark.asyncio
async def test_algorithm_confusion_and_forged_signature_rejected(apple_signer, settings):
    private, client, verifier = await verifier_fixture(apple_signer, settings)
    async with client:
        nonce = "random-unit-test-nonce-123"
        token = jwt.encode({"sub": "attacker"}, "fake-hmac-key-that-is-not-an-apple-key", algorithm="HS256", headers={"kid": "unit-test-key"})
        with pytest.raises(ServiceError) as error:
            await verifier.verify(token, nonce)
        assert error.value.status == 401
        different_private = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        with pytest.raises(ServiceError):
            await verifier.verify(make_token(different_private, settings, nonce), nonce)


def test_session_tokens_cannot_be_forged(settings):
    sessions = Sessions(settings)
    owner = str(uuid4())
    valid = sessions.issue(owner)
    assert sessions.verify(valid) == owner
    claims = jwt.decode(valid, options={"verify_signature": False})
    wrong = jwt.encode(claims, "a-different-cryptographic-secret-123456789", algorithm="HS256")
    with pytest.raises(ServiceError) as error:
        sessions.verify(wrong)
    assert error.value.status == 401
    expired = jwt.encode({**claims, "exp": 0}, settings.session_secret, algorithm="HS256")
    with pytest.raises(ServiceError):
        sessions.verify(expired)
