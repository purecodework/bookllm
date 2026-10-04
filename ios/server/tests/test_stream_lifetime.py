"""Exercise cancellation ownership without TestClient buffering away disconnects."""
import asyncio
from dataclasses import replace

import pytest

from translation_service.app import create_app
from translation_service.billing import TokenUsage
from translation_service.ledger import ServiceError
from translation_service.models import TranslationRequest
from translation_service.provider import AmbiguousProviderFailure, DefiniteProviderFailure
from translation_service.streams import TranslationStreamJob
from conftest import create_account
from test_api import Identity, Purchase, fast_body


class ControlledStream:
    def __init__(self, *, failure=None, before_first=False):
        self.release = asyncio.Event()
        self.first_started = asyncio.Event()
        self.failure = failure
        self.before_first = before_first
        self.calls = 0
        self.closed = False

    async def stream(self, messages, *, max_tokens=None):
        self.calls += 1
        try:
            self.first_started.set()
            if self.before_first:
                await self.release.wait()
            yield "第一段"
            if not self.before_first:
                await self.release.wait()
            if self.failure:
                raise self.failure
            yield "，完整末尾。"
            yield TokenUsage(20, 10)
        finally:
            self.closed = True


def stream_app(settings, model):
    app = create_app(settings, identity_verifier=Identity(), purchase_verifier=Purchase(), provider=model)
    owner = create_account(app.state.ledger)
    endpoint = next(route.endpoint for route in app.routes if getattr(route, "path", None) == "/v1/translate/stream")
    request = TranslationRequest.model_validate(fast_body())
    return app, owner, endpoint, request


async def finish_workers(app):
    tasks = tuple(app.state.stream_tasks)
    if tasks:
        await asyncio.wait_for(asyncio.gather(*tasks), timeout=2)


@pytest.mark.asyncio
async def test_disconnect_after_real_token_completes_paid_work_and_resume_replays(settings):
    model = ControlledStream()
    app, owner, endpoint, request = stream_app(settings, model)
    async with app.router.lifespan_context(app):
        response = await endpoint(request, owner)
        subscriber = response.body_iterator
        assert '"delta":"第一段"' in await anext(subscriber)
        await subscriber.aclose()  # Actual response generator cancellation/disconnect path.
        assert not model.closed
        assert app.state.ledger.request_status(owner, request.requestID)["status"] == "dispatched"
        with pytest.raises(ServiceError) as pending:
            await endpoint(request, owner)
        assert pending.value.status == 409 and pending.value.retry_after == 1
        held = app.state.ledger.request_status(owner, request.requestID)["reservedPoints"]
        assert app.state.ledger.account(owner)["points"] == 100 - held
        model.release.set()
        await finish_workers(app)
        state = app.state.ledger.request_status(owner, request.requestID)
        assert state["status"] == "completed"
        assert state["result"] == {"text": "第一段，完整末尾。"}
        replay = await endpoint(request, owner)
        output = "".join([part async for part in replay.body_iterator])
        assert '"delta":"第一段，完整末尾。"' in output and '"done":true' in output
        assert model.calls == 1
        assert app.state.ledger.account(owner)["points"] == 99
        assert not app.state.stream_tasks


@pytest.mark.asyncio
async def test_request_cancelled_before_first_token_does_not_cancel_upstream(settings):
    model = ControlledStream(before_first=True)
    app, owner, endpoint, request = stream_app(settings, model)
    async with app.router.lifespan_context(app):
        http_request = asyncio.create_task(endpoint(request, owner))
        await asyncio.wait_for(model.first_started.wait(), timeout=2)
        http_request.cancel()
        with pytest.raises(asyncio.CancelledError):
            await http_request
        assert not model.closed
        model.release.set()
        await finish_workers(app)
        assert app.state.ledger.request_status(owner, request.requestID)["status"] == "completed"
        assert model.calls == 1 and app.state.ledger.account(owner)["points"] == 99


@pytest.mark.asyncio
@pytest.mark.parametrize("failure,status,balance", [
    (AmbiguousProviderFailure(503, "provider connection lost", 5), "uncertain", None),
    (DefiniteProviderFailure(502, "invalid finish marker"), "refunded", 100),
])
async def test_disconnect_does_not_hide_genuine_upstream_failure(settings, failure, status, balance):
    model = ControlledStream(failure=failure)
    app, owner, endpoint, request = stream_app(settings, model)
    async with app.router.lifespan_context(app):
        response = await endpoint(request, owner)
        subscriber = response.body_iterator
        await anext(subscriber)
        await subscriber.aclose()
        model.release.set()
        await finish_workers(app)
        state = app.state.ledger.request_status(owner, request.requestID)
        assert state["status"] == status and "result" not in state
        assert app.state.ledger.account(owner)["points"] == (100 - state["reservedPoints"] if balance is None else balance)


@pytest.mark.asyncio
async def test_shutdown_cancels_only_unfinished_application_workers_and_marks_uncertain(settings):
    model = ControlledStream()
    app, owner, endpoint, request = stream_app(replace(settings, stream_shutdown_grace_seconds=0), model)
    async with app.router.lifespan_context(app):
        response = await endpoint(request, owner)
        assert '"delta"' in await anext(response.body_iterator)
        assert app.state.stream_tasks
    assert model.closed
    assert not app.state.stream_tasks
    assert app.state.ledger.request_status(owner, request.requestID)["status"] == "uncertain"
    state = app.state.ledger.request_status(owner, request.requestID)
    assert app.state.ledger.account(owner)["points"] == 100 - state["reservedPoints"]
    await response.body_iterator.aclose()
    with pytest.raises(ServiceError) as closing:
        await endpoint(request, owner)
    assert closing.value.status == 503


@pytest.mark.asyncio
async def test_shutdown_grace_allows_completion_and_retains_replay(settings):
    model = ControlledStream()
    app, owner, endpoint, request = stream_app(settings, model)
    async with app.router.lifespan_context(app):
        response = await endpoint(request, owner)
        await anext(response.body_iterator)
        await response.body_iterator.aclose()
        asyncio.get_running_loop().call_soon(model.release.set)
    assert app.state.ledger.request_status(owner, request.requestID)["status"] == "completed"
    assert model.closed and not app.state.stream_tasks


@pytest.mark.asyncio
async def test_slow_subscriber_queue_is_bounded_and_never_blocks_completion(settings):
    class ManyTokens:
        async def stream(self, messages, *, max_tokens=None):
            for _ in range(300):
                yield "字"
            yield TokenUsage(20, 300)
    app, owner, endpoint, request = stream_app(settings, ManyTokens())
    async with app.router.lifespan_context(app):
        response = await endpoint(request, owner)
        # Deliberately never consume until the worker finishes: no infinite queue/backpressure.
        await finish_workers(app)
        output = "".join([part async for part in response.body_iterator])
        assert '"error"' in output and '"status":409' in output
        assert '"done":true' not in output  # Partial SSE is never passed off as a complete translation.
        state = app.state.ledger.request_status(owner, request.requestID)
        assert state["status"] == "completed" and state["result"]["text"] == "字" * 300
        assert app.state.ledger.account(owner)["points"] == 99


@pytest.mark.asyncio
async def test_detaching_discards_subscriber_buffer_without_cancelling_job(settings):
    model = ControlledStream()
    app, owner, endpoint, request = stream_app(settings, model)
    async with app.router.lifespan_context(app):
        # The job class exposes a fixed upper bound independent of document length.
        job = TranslationStreamJob(app.state.ledger, model, owner, "unused", [])
        for index in range(10):
            job.publish({"delta": str(index)})
        assert job.queue.maxsize == 64 and job.queue.qsize() == 10
        job.detach()
        for _ in range(1000):
            job.publish({"delta": "ignored"})
        assert job.queue.empty()


@pytest.mark.asyncio
async def test_shutdown_of_worker_cancelled_before_start_refunds_only_unsubmitted_reservation(settings):
    model = ControlledStream()
    app, owner, endpoint, request = stream_app(settings, model)
    async with app.router.lifespan_context(app):
        app.state.ledger.reserve(owner, "not-dispatched", "translate", "hash", 1)
        job = TranslationStreamJob(app.state.ledger, model, owner, "not-dispatched", [])
        worker = asyncio.create_task(job.run())
        worker.cancel()  # Python has never entered the coroutine body, so its finally cannot run.
        await asyncio.gather(worker, return_exceptions=True)
        await job.shutdown_unstarted()
        assert app.state.ledger.request_status(owner, "not-dispatched")["status"] == "refunded"
        assert app.state.ledger.account(owner)["points"] == 100
        assert model.calls == 0
        assert (await job.ready).status == 503
