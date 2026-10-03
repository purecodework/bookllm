import asyncio
import hashlib
import time
from dataclasses import replace

from fastapi.testclient import TestClient
import pytest

from translation_service.app import create_app
from translation_service.ledger import ServiceError
from translation_service.provider import AmbiguousProviderFailure, DefiniteProviderFailure
from translation_service.purchases import VerifiedPurchase
from conftest import create_account


class Identity:
    async def verify(self, token, nonce):
        if token != "valid-test-token-" * 3:
            raise ServiceError(401, "Invalid token")
        return {"sub": "test-apple-sub", "exp": time.time() + 600}


class Purchase:
    def verify(self, jws, owner):
        if jws != "verified-test-jws-" * 3:
            raise ServiceError(400, "Invalid receipt")
        return VerifiedPurchase("Sandbox:tx-1", "app.bookllm.credits.100", hashlib.sha256(jws.encode()).hexdigest())


class Model:
    def __init__(self, outcome="译文"):
        self.calls = 0
        self.outcome = outcome

    async def complete(self, messages):
        self.calls += 1
        if isinstance(self.outcome, BaseException):
            raise self.outcome
        return self.outcome

    async def terms(self, messages):
        self.calls += 1
        return [{"source": "Alice", "target": "爱丽丝"}]


def body(request_id="doc:0:translate"):
    return {
        "requestID": request_id, "source": "Hello, world.", "context": "", "draft": "", "stage": "translate",
        "options": {
            "targetLanguage": "简体中文", "quality": "refined",
            "style": {"id": "faithful", "name": "忠实清晰", "subtitle": "准确", "instruction": "Faithful prose"},
            "glossary": [],
            "preferences": {"foreignText": "bilingual", "annotations": "cultural", "sparseNotes": True, "extraLanguageReview": True},
        },
    }


def setup_client(settings, model=None):
    app = create_app(settings, identity_verifier=Identity(), purchase_verifier=Purchase(), provider=model or Model())
    owner = create_account(app.state.ledger)
    header = {"Authorization": "Bearer " + app.state.sessions.issue(owner)}
    return app, TestClient(app), owner, header


def test_native_session_purchase_and_account_contracts(settings):
    app = create_app(settings, identity_verifier=Identity(), purchase_verifier=Purchase(), provider=Model())
    with TestClient(app) as client:
        login_body = {"identityToken": "valid-test-token-" * 3, "nonce": "random-nonce-123456789"}
        response = client.post("/v1/session", json=login_body)
        assert response.status_code == 200
        value = response.json()
        assert value["points"] == 0 and value["ownAPIUnlocked"] is False
        assert "accountID" in value and "token" in value
        headers = {"Authorization": "Bearer " + value["token"]}
        receipt = {"signedTransaction": "verified-test-jws-" * 3}
        assert client.post("/v1/purchases", json=receipt, headers=headers).json()["points"] == 100
        assert client.post("/v1/purchases", json=receipt, headers=headers).json()["points"] == 100
        assert client.get("/v1/account", headers=headers).json()["points"] == 100
        assert client.post("/v1/session", json=login_body).status_code == 401


def test_replay_translate_and_glossary_never_call_model_twice(settings):
    model = Model()
    app, client, owner, headers = setup_client(settings, model)
    with client:
        request = body()
        for _ in range(2):
            response = client.post("/v1/translate", json=request, headers=headers)
            assert response.status_code == 200 and response.json() == {"text": "译文"}
        assert model.calls == 1
        assert app.state.ledger.account(owner)["points"] == 99
        request["source"] = "Changed source"
        assert client.post("/v1/translate", json=request, headers=headers).status_code == 409
        glossary = {"requestID": "doc:glossary", "source": "Alice " * 300, "target": "简体中文"}
        response = client.post("/v1/glossary", json=glossary, headers=headers)
        assert response.status_code == 200 and response.json()[0]["target"] == "爱丽丝"
        assert client.post("/v1/glossary", json=glossary, headers=headers).status_code == 200
        assert model.calls == 2
        assert app.state.ledger.account(owner)["points"] == 97


@pytest.mark.parametrize("path", ["/v1/account", "/v1/requests/doc", "/v1/translate", "/v1/glossary", "/v1/purchases"])
def test_private_endpoints_require_session(settings, path):
    app, client, owner, headers = setup_client(settings)
    with client:
        if path in ("/v1/account", "/v1/requests/doc"):
            response = client.get(path)
        else:
            response = client.post(path, json={})
        assert response.status_code == 401
        assert response.headers["WWW-Authenticate"] == "Bearer"


def test_status_is_scoped_and_invalid_quality_never_charges(settings):
    app, client, owner, headers = setup_client(settings)
    another = create_account(app.state.ledger, subject="other")
    other_headers = {"Authorization": "Bearer " + app.state.sessions.issue(another)}
    with client:
        assert client.post("/v1/translate", json=body(), headers=headers).status_code == 200
        status = client.get("/v1/requests/doc:0:translate", headers=headers)
        assert status.json()["status"] == "completed"
        assert status.json()["result"] == {"text": "译文"}
        assert client.get("/v1/requests/doc:0:translate", headers=other_headers).status_code == 404
        invalid = body("invalid")
        invalid.update({"stage": "editor", "draft": "Draft"})
        assert client.post("/v1/translate", json=invalid, headers=headers).status_code == 422
        assert app.state.ledger.account(owner)["points"] == 99


def test_definite_failure_refunds_while_ambiguous_failure_stays_pending(settings):
    model = Model(DefiniteProviderFailure(429, "retry", 2))
    app, client, owner, headers = setup_client(settings, model)
    with client:
        response = client.post("/v1/translate", json=body(), headers=headers)
        assert response.status_code == 429 and response.headers["Retry-After"] == "2"
        assert app.state.ledger.account(owner)["points"] == 100
        model.outcome = AmbiguousProviderFailure(503, "uncertain", 5)
        response = client.post("/v1/translate", json=body(), headers=headers)
        assert response.status_code == 503
        assert app.state.ledger.account(owner)["points"] == 99
        assert app.state.ledger.request_status(owner, "doc:0:translate")["status"] == "uncertain"
        assert client.post("/v1/translate", json=body(), headers=headers).status_code == 409
        assert model.calls == 2


def test_concurrency_429_is_not_a_charge(settings):
    app, client, owner, headers = setup_client(replace(settings, per_account_concurrency=1))
    app.state.ledger.reserve(owner, "ongoing", "translate", "h", 1)
    with client:
        response = client.post("/v1/translate", json=body(), headers=headers)
        assert response.status_code == 429
        assert response.headers["Retry-After"] == "2"
        assert app.state.ledger.account(owner)["points"] == 99


def test_body_size_limit(settings):
    app, client, owner, headers = setup_client(settings)
    with client:
        response = client.post("/v1/translate", content="x" * 262145, headers=headers)
        assert response.status_code == 413


class StreamingModel(Model):
    async def stream(self, messages):
        self.calls += 1
        yield "你好"
        await asyncio.sleep(0)
        if isinstance(self.outcome, BaseException):
            raise self.outcome
        yield "，世界。"


def fast_body(request_id="doc:stream"):
    request = body(request_id)
    request["options"]["quality"] = "fast"
    return request


def test_true_stream_endpoint_and_cached_replay(settings):
    model = StreamingModel()
    app, client, owner, headers = setup_client(settings, model)
    with client:
        response = client.post("/v1/translate/stream", json=fast_body(), headers=headers)
        assert response.status_code == 200
        assert response.headers["Content-Type"].startswith("text/event-stream")
        assert response.headers["X-Accel-Buffering"] == "no"
        assert 'data:{"delta":"你好"}' in response.text
        assert 'data:{"delta":"，世界。"}' in response.text
        assert response.text.endswith('data:{"done":true}\n\n')
        assert app.state.ledger.request_status(owner, "doc:stream")["result"] == {"text": "你好，世界。"}
        replay = client.post("/v1/translate/stream", json=fast_body(), headers=headers)
        assert 'data:{"delta":"你好，世界。"}' in replay.text
        assert model.calls == 1
        assert app.state.ledger.account(owner)["points"] == 99
        # Same request can also retrieve the completed result through the ordinary endpoint.
        assert client.post("/v1/translate", json=fast_body(), headers=headers).json() == {"text": "你好，世界。"}


@pytest.mark.parametrize("failure,expected_points,expected_status", [
    (DefiniteProviderFailure(502, "incomplete"), 100, "refunded"),
    (AmbiguousProviderFailure(503, "uncertain", 5), 99, "uncertain"),
])
def test_stream_failures_never_send_done(settings, failure, expected_points, expected_status):
    model = StreamingModel(failure)
    app, client, owner, headers = setup_client(settings, model)
    with client:
        response = client.post("/v1/translate/stream", json=fast_body(), headers=headers)
        assert response.status_code == 200  # Headers already sent; error is an SSE event.
        assert '"error":' in response.text and '"done":true' not in response.text
        assert app.state.ledger.account(owner)["points"] == expected_points
        assert app.state.ledger.request_status(owner, "doc:stream")["status"] == expected_status


def test_refined_stream_is_rejected_before_reserving(settings):
    app, client, owner, headers = setup_client(settings, StreamingModel())
    with client:
        assert client.post("/v1/translate/stream", json=body(), headers=headers).status_code == 422
        assert app.state.ledger.account(owner)["points"] == 100
