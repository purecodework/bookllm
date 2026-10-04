"""Real-token settlement, independent reservations, and resumable low-credit stages."""
from concurrent.futures import ThreadPoolExecutor
from dataclasses import replace
import json

import httpx
import pytest

from translation_service.app import create_app
from translation_service.billing import TokenBudget, TokenUsage, UsageText
from translation_service.ledger import Ledger, ServiceError
from translation_service.provider import DeepSeek, DefiniteProviderFailure
from conftest import create_account
from test_api import Model, body, fast_body, setup_client
from test_provider_prompts import TokenStream


def spend_to(ledger, owner, remaining):
    amount = ledger.account(owner)["points"] - remaining
    if amount:
        ledger.reserve(owner, "prior-consumption", "translate", "prior", amount)
        ledger.dispatch(owner, "prior-consumption")
        ledger.complete(owner, "prior-consumption", {"text": "earlier completed document"})


def test_usage_difference_refunds_atomically_and_zero_balance_cache_is_free(ledger):
    owner = create_account(ledger)
    budget = TokenBudget(800, 300, 2700, 1000)
    held = ledger.reserve_tokens(owner, "stage", "translate", "payload", budget)
    assert held.max_tokens == 2700
    assert ledger.account(owner)["points"] == 96
    ledger.dispatch(owner, "stage")
    ledger.complete(owner, "stage", {"text": "complete"}, TokenUsage(700, 500))
    state = ledger.request_status(owner, "stage")
    assert state["reservedPoints"] == 4 and state["points"] == 2
    assert state["tokenUsage"] == {"prompt_tokens": 700, "completion_tokens": 500, "total_tokens": 1200}
    assert ledger.account(owner)["points"] == 98
    # Changing the later estimate/pricing never changes an already-settled request.
    spend_to(ledger, owner, 0)
    replay = ledger.reserve_tokens(owner, "stage", "translate", "payload", replace(budget, tokens_per_point=1))
    assert replay.cached == {"text": "complete"}
    assert ledger.account(owner)["points"] == 0


def test_concurrent_usage_refunds_preserve_balance_and_events(settings):
    ledger = Ledger(settings.database_path, 32, 32)
    owner = create_account(ledger)
    budget = TokenBudget(500, 500, 3500, 1000)
    for index in range(20):
        ledger.reserve_tokens(owner, str(index), "translate", str(index), budget)
        ledger.dispatch(owner, str(index))
    assert ledger.account(owner)["points"] == 20
    with ThreadPoolExecutor(max_workers=12) as pool:
        list(pool.map(lambda index: ledger.complete(owner, str(index), {"text": str(index)}, TokenUsage(500, 500)), range(20)))
    assert ledger.account(owner)["points"] == 80
    with ledger.connection() as db:
        assert db.execute("SELECT SUM(delta) FROM credit_events WHERE account_id=?", (owner,)).fetchone()[0] == 80
    with pytest.raises(ServiceError):
        ledger.complete(owner, "0", {"text": "duplicate"}, TokenUsage(500, 500))
    assert ledger.account(owner)["points"] == 80


def test_low_credit_fits_output_and_topup_continues_next_stage_with_same_id(ledger):
    owner = create_account(ledger)
    spend_to(ledger, owner, 2)
    budget = TokenBudget(700, 400, 4000, 1000)
    reservation = ledger.reserve_tokens(owner, "chapter:translate", "translate", "first", budget)
    assert reservation.max_tokens == 1300  # Do not require the normal 4,000-output maximum.
    ledger.dispatch(owner, "chapter:translate")
    ledger.complete(owner, "chapter:translate", {"text": "saved draft"}, TokenUsage(700, 700))
    assert ledger.account(owner)["points"] == 0
    with pytest.raises(ServiceError) as exhausted:
        ledger.reserve_tokens(owner, "chapter:proofread", "translate", "second", budget)
    assert exhausted.value.status == 402
    with pytest.raises(ServiceError) as unstarted:
        ledger.request_status(owner, "chapter:proofread")
    assert unstarted.value.status == 404  # No charge or phantom pending entry.
    ledger.redeem(owner, "Sandbox:topup", "app.bookllm.credits.100", "receipt")
    assert ledger.reserve_tokens(owner, "chapter:translate", "translate", "first", budget).cached == {"text": "saved draft"}
    next_pass = ledger.reserve_tokens(owner, "chapter:proofread", "translate", "second", budget)
    ledger.dispatch(owner, "chapter:proofread")
    ledger.complete(owner, "chapter:proofread", {"text": "checked draft"}, TokenUsage(850, 700))
    assert next_pass.max_tokens == 4000
    assert ledger.account(owner)["points"] == 98


def test_usage_over_estimate_is_explicit_and_never_lost(ledger):
    owner = create_account(ledger)
    spend_to(ledger, owner, 2)
    budget = TokenBudget(500, 500, 1500, 1000)
    ledger.reserve_tokens(owner, "underestimate", "translate", "payload", budget)
    ledger.dispatch(owner, "underestimate")
    ledger.complete(owner, "underestimate", {"text": "complete"}, TokenUsage(1900, 1400))
    assert ledger.account(owner)["points"] == 0
    assert ledger.account(owner)["creditDebt"] == 0
    state = ledger.request_status(owner, "underestimate")
    assert state["points"] == 2 and state["actualEquivalentPoints"] == 4
    assert state["absorbedPoints"] == 2
    assert ledger.reserve_tokens(owner, "underestimate", "translate", "payload", budget).cached == {"text": "complete"}
    ledger.redeem(owner, "Sandbox:topup", "app.bookllm.credits.100", "receipt")
    assert ledger.account(owner)["points"] == 100 and ledger.account(owner)["creditDebt"] == 0
    with ledger.connection() as db:
        assert db.execute("SELECT SUM(delta) FROM debt_events WHERE account_id=?", (owner,)).fetchone()[0] is None
        assert db.execute("SELECT SUM(delta) FROM credit_events WHERE account_id=?", (owner,)).fetchone()[0] == 100


def test_context_draft_and_glossary_prompt_are_in_reservation_estimate(settings):
    from translation_service.models import TranslationRequest
    from translation_service.prompts import translation_messages
    payload = body()
    normal = TokenBudget.for_request(settings, translation_messages(TranslationRequest.model_validate(payload)), payload["source"], "translate")
    payload.update(context="前一章 " * 300, draft="原始译稿 " * 300, stage="proofread")
    payload["options"]["glossary"] = [{"source": "Hello", "target": "你好"}]
    richer = TokenBudget.for_request(settings, translation_messages(TranslationRequest.model_validate(payload)), payload["source"], "translate")
    assert richer.estimated_input_tokens > normal.estimated_input_tokens + 1000


def test_actual_usage_402_then_topup_endpoint_keeps_completed_passes(settings):
    from translation_service.models import TranslationRequest
    from translation_service.prompts import translation_messages
    request = body("partial:0")
    budget = TokenBudget.for_request(settings, translation_messages(TranslationRequest.model_validate(request)), request["source"], "translate")
    needed = (budget.estimated_input_tokens + budget.minimum_output_tokens + settings.tokens_per_point - 1) // settings.tokens_per_point
    class CostedModel(Model):
        async def complete(self, messages, *, max_tokens=None):
            self.calls += 1
            return UsageText("译文", TokenUsage(needed * settings.tokens_per_point - 10, 10))
    model = CostedModel()
    app, client, owner, headers = setup_client(settings, model)
    spend_to(app.state.ledger, owner, needed)
    with client:
        first = client.post("/v1/translate", json=request, headers=headers)
        assert first.status_code == 200 and first.json() == {"text": "译文"}
        assert app.state.ledger.account(owner)["points"] == 0
        next_request = body("partial:1")
        assert client.post("/v1/translate", json=next_request, headers=headers).status_code == 402
        assert model.calls == 1
        app.state.ledger.redeem(owner, "Sandbox:topup", "app.bookllm.credits.100", "receipt")
        assert client.post("/v1/translate", json=body("partial:0"), headers=headers).json() == {"text": "译文"}
        assert client.post("/v1/translate", json=next_request, headers=headers).status_code == 200
        assert model.calls == 2 and app.state.ledger.account(owner)["points"] == 100 - needed


@pytest.mark.asyncio
async def test_deepseek_complete_usage_and_max_tokens_are_authoritative(settings):
    def response(request):
        payload = json.loads(request.content)
        assert payload["max_tokens"] == 650 and payload["stream"] is False
        return httpx.Response(200, json={"choices": [{"message": {"content": "完整译文"}, "finish_reason": "stop"}], "usage": {"prompt_tokens": 1300, "completion_tokens": 420, "total_tokens": 1720}})
    async with httpx.AsyncClient(transport=httpx.MockTransport(response)) as client:
        result = await DeepSeek(settings, client).complete([], max_tokens=650)
    assert str(result) == "完整译文" and result.usage == TokenUsage(1300, 420)


@pytest.mark.asyncio
async def test_deepseek_terms_retains_usage(settings):
    response = {"choices": [{"message": {"content": '[{"source":"Alice","target":"爱丽丝"}]'}, "finish_reason": "stop"}], "usage": {"prompt_tokens": 1400, "completion_tokens": 80}}
    async with httpx.AsyncClient(transport=httpx.MockTransport(lambda _: httpx.Response(200, json=response))) as client:
        terms = await DeepSeek(settings, client).terms([], max_tokens=300)
    assert terms == [{"source": "Alice", "target": "爱丽丝"}] and terms.usage == TokenUsage(1400, 80)


@pytest.mark.asyncio
@pytest.mark.parametrize("usage", [None, {"prompt_tokens": True, "completion_tokens": 10}, {"prompt_tokens": -1, "completion_tokens": 10}, {"prompt_tokens": 3, "completion_tokens": 4, "total_tokens": 99}])
async def test_missing_or_malformed_usage_is_explicit_refundable_failure(settings, usage):
    response = {"choices": [{"message": {"content": "complete"}, "finish_reason": "stop"}], "usage": usage}
    async with httpx.AsyncClient(transport=httpx.MockTransport(lambda _: httpx.Response(200, json=response))) as client:
        with pytest.raises(DefiniteProviderFailure):
            await DeepSeek(settings, client).complete([])


@pytest.mark.asyncio
async def test_stream_tail_usage_after_stop_is_required_and_separate_from_text(settings):
    frames = [
        'data: {"choices":[{"delta":{"content":"译文"},"finish_reason":"stop"}]}\n\n',
        'data: {"choices":[],"usage":{"prompt_tokens":2400,"completion_tokens":700,"total_tokens":3100}}\n\n',
        'data: [DONE]\n\n',
    ]
    def respond(request):
        payload = json.loads(request.content)
        assert payload["stream_options"] == {"include_usage": True} and payload["max_tokens"] == 750
        return httpx.Response(200, stream=TokenStream(frames))
    async with httpx.AsyncClient(transport=httpx.MockTransport(respond)) as client:
        events = [event async for event in DeepSeek(settings, client).stream([], max_tokens=750)]
    assert events == ["译文", TokenUsage(2400, 700)]


@pytest.mark.asyncio
async def test_stream_stop_without_usage_never_claims_actual_billing(settings):
    frames = ['data: {"choices":[{"delta":{"content":"译文"},"finish_reason":"stop"}]}\n\n', 'data: [DONE]\n\n']
    async with httpx.AsyncClient(transport=httpx.MockTransport(lambda _: httpx.Response(200, stream=TokenStream(frames)))) as client:
        generator = DeepSeek(settings, client).stream([])
        assert await anext(generator) == "译文"
        with pytest.raises(DefiniteProviderFailure):
            await anext(generator)


def test_unmetered_injected_provider_is_refunded_rather_than_character_billed(settings):
    class MissingUsage:
        async def complete(self, messages, *, max_tokens=None):
            return "result without usage"
    app, client, owner, headers = setup_client(settings, MissingUsage())
    with client:
        response = client.post("/v1/translate", json=body(), headers=headers)
        assert response.status_code == 502
        assert app.state.ledger.account(owner)["points"] == 100
        assert app.state.ledger.request_status(owner, body()["requestID"])["status"] == "refunded"


def test_temporary_reserved_credit_waits_then_retries_without_duplicate_spend(ledger):
    owner = create_account(ledger)
    spend_to(ledger, owner, 2)
    holder = TokenBudget(200, 128, 1800, 1000)
    following = TokenBudget(600, 128, 300, 1000)
    ledger.reserve_tokens(owner, "ongoing", "translate", "one", holder)
    ledger.dispatch(owner, "ongoing")
    with pytest.raises(ServiceError) as occupied:
        ledger.reserve_tokens(owner, "following", "translate", "two", following)
    assert occupied.value.status == 409 and occupied.value.retry_after == 1
    ledger.complete(owner, "ongoing", {"text": "done"}, TokenUsage(200, 200))
    assert ledger.account(owner)["points"] == 1
    assert ledger.reserve_tokens(owner, "following", "translate", "two", following).max_tokens == 300
    ledger.dispatch(owner, "following")
    ledger.complete(owner, "following", {"text": "next"}, TokenUsage(600, 250))
    assert ledger.account(owner)["points"] == 0
    with pytest.raises(ServiceError) as exhausted:
        ledger.reserve_tokens(owner, "last", "translate", "three", following)
    assert exhausted.value.status == 402 and exhausted.value.retry_after is None


def test_optional_language_and_review_fields_keep_historical_hash():
    from translation_service.ledger import content_hash
    original = body()
    expanded = json.loads(json.dumps(original))
    expanded["options"]["sourceLanguage"] = None
    expanded["reviewNotes"] = None
    assert content_hash("translate", original) == content_hash("translate", expanded)
    expanded["options"]["sourceLanguage"] = "en"
    assert content_hash("translate", original) != content_hash("translate", expanded)
    expanded["options"]["sourceLanguage"] = None
    expanded["reviewNotes"] = "Continue this novel voice"
    assert content_hash("translate", original) != content_hash("translate", expanded)


@pytest.mark.asyncio
@pytest.mark.parametrize("operation", ["translate", "glossary"])
async def test_nonstream_pause_keeps_model_worker_settling_and_replays_once(settings, operation):
    import asyncio
    from translation_service.billing import UsageTerms
    from translation_service.models import GlossaryRequest, TranslationRequest
    from test_api import Identity, Purchase

    class Controlled:
        def __init__(self):
            self.started = asyncio.Event()
            self.release = asyncio.Event()
            self.calls = 0

        async def output(self):
            self.calls += 1
            self.started.set()
            await self.release.wait()

        async def complete(self, messages, *, max_tokens=None):
            await self.output()
            return UsageText("checked whole draft", TokenUsage(400, 200))

        async def terms(self, messages, *, max_tokens=None):
            await self.output()
            return UsageTerms([{"source": "Alice", "target": "爱丽丝"}], TokenUsage(400, 200))

    model = Controlled()
    app = create_app(settings, identity_verifier=Identity(), purchase_verifier=Purchase(), provider=model)
    owner = create_account(app.state.ledger)
    if operation == "translate":
        request = TranslationRequest.model_validate(body("pause:proofread"))
        expected = {"text": "checked whole draft"}
    else:
        request = GlossaryRequest(requestID="pause:terms", source="Alice", target="简体中文")
        expected = [{"source": "Alice", "target": "爱丽丝"}]
    endpoint = next(route.endpoint for route in app.routes if getattr(route, "path", None) == "/v1/" + operation)
    async with app.router.lifespan_context(app):
        subscriber = asyncio.create_task(endpoint(request, owner))
        await asyncio.wait_for(model.started.wait(), timeout=2)
        subscriber.cancel()
        with pytest.raises(asyncio.CancelledError):
            await subscriber
        assert app.state.request_tasks
        assert app.state.ledger.request_status(owner, request.requestID)["status"] == "dispatched"
        model.release.set()
        await asyncio.wait_for(asyncio.gather(*tuple(app.state.request_tasks)), timeout=2)
        assert app.state.ledger.request_status(owner, request.requestID)["result"] == expected
        assert await endpoint(request, owner) == expected
        assert model.calls == 1 and app.state.ledger.account(owner)["points"] == 99


def test_legacy_database_migration_preserves_completed_charges(tmp_path):
    import sqlite3
    database = str(tmp_path / "legacy.sqlite3")
    with sqlite3.connect(database) as db:
        db.executescript('''
            CREATE TABLE accounts (id TEXT PRIMARY KEY,apple_subject TEXT UNIQUE NOT NULL,points INTEGER NOT NULL DEFAULT 0 CHECK(points >= 0),own_api_unlocked INTEGER NOT NULL DEFAULT 0,created_at REAL NOT NULL);
            CREATE TABLE requests (account_id TEXT NOT NULL REFERENCES accounts(id),request_id TEXT NOT NULL,payload_hash TEXT NOT NULL,operation TEXT NOT NULL,cost INTEGER NOT NULL CHECK(cost>0),status TEXT NOT NULL,response_json TEXT,attempts INTEGER NOT NULL DEFAULT 1,created_at REAL NOT NULL,updated_at REAL NOT NULL,PRIMARY KEY(account_id,request_id));
            INSERT INTO accounts VALUES('account','apple',97,0,1);
            INSERT INTO requests VALUES('account','legacy:0','hash','translate',3,'completed','{"text":"old cached translation"}',1,1,1);
        ''')
    ledger = Ledger(database)
    state = ledger.request_status("account", "legacy:0")
    assert state["points"] == 3 and state["reservedPoints"] == 3
    assert state["billingMode"] == "legacy" and state["actualEquivalentPoints"] is None
    assert ledger.reserve_tokens("account", "legacy:0", "translate", "hash", TokenBudget(9000, 5000, 8000, 1)).cached == {"text": "old cached translation"}
    assert ledger.account("account")["points"] == 97 and ledger.account("account")["creditDebt"] == 0
    # Multiple initialization passes do not change historical charges.
    assert Ledger(database).request_status("account", "legacy:0")["points"] == 3


def test_concurrent_ledger_startup_migrations_are_serialized(tmp_path):
    database = str(tmp_path / "workers.sqlite3")
    with ThreadPoolExecutor(max_workers=8) as pool:
        ledgers = list(pool.map(lambda _: Ledger(database), range(16)))
    with ledgers[0].connection() as db:
        columns = {row["name"] for row in db.execute("PRAGMA table_info(requests)")}
    assert {"reserved_cost", "tokens_per_point", "absorbed_points", "actual_equivalent_points"} <= columns


def test_token_usage_rounds_total_once_and_validates_no_fake_values():
    assert TokenUsage(500, 500).points(1000) == 1
    assert TokenUsage(1000, 1).points(1000) == 2
    with pytest.raises(ValueError):
        TokenUsage(-1, 10)
    with pytest.raises(ValueError):
        TokenUsage(True, 10)
