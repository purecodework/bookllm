import asyncio
from contextlib import asynccontextmanager
import hashlib

import httpx
from fastapi import Depends, FastAPI, Request
from fastapi.responses import JSONResponse, StreamingResponse
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from starlette.concurrency import run_in_threadpool

from .auth import AppleIdentityVerifier, Sessions
from .billing import TokenBudget, TokenUsage
from .config import Settings
from .ledger import Ledger, ServiceError, content_hash
from .marketplace import Marketplace, routes
from .models import GlossaryRequest, NotificationRequest, PurchaseRequest, Quality, SessionRequest, Stage, TranslationRequest
from .prompts import glossary_messages, translation_messages
from .provider import AmbiguousProviderFailure, DeepSeek, DefiniteProviderFailure
from .purchases import ApplePurchaseVerifier
from .streams import TranslationStreamJob, sse_event


def create_app(settings: Settings, *, identity_verifier=None, purchase_verifier=None, provider=None):
    # Dependency injection is only a Python construction API for tests, never an HTTP/env bypass.
    ledger = Ledger(settings.database_path, settings.per_account_concurrency, settings.global_concurrency)
    sessions = Sessions(settings)
    client = httpx.AsyncClient(follow_redirects=False, limits=httpx.Limits(max_connections=settings.global_concurrency + 4, max_keepalive_connections=settings.global_concurrency))
    identity = identity_verifier or AppleIdentityVerifier(client, settings.apple_bundle_id)
    purchases = purchase_verifier or ApplePurchaseVerifier(settings)
    model = provider or DeepSeek(settings, client)

    stream_tasks = set()
    stream_jobs = {}
    request_tasks = set()

    @asynccontextmanager
    async def lifespan(app):
        try:
            yield
        finally:
            app.state.shutting_down = True
            workers = stream_tasks | request_tasks
            if workers:
                jobs = dict(stream_jobs)
                _, pending = await asyncio.wait(tuple(workers), timeout=app.state.stream_shutdown_grace_seconds)
                for task in pending:
                    task.cancel()
                if pending:
                    await asyncio.gather(*pending, return_exceptions=True)
                    for task in pending:
                        job = jobs.get(task)
                        if job is not None and not job.ready.done():
                            await job.shutdown_unstarted()
            await client.aclose()

    app = FastAPI(title="BookLLM Cloud", version="1.0.0", lifespan=lifespan, docs_url=None, redoc_url=None)
    app.state.ledger = ledger
    app.state.sessions = sessions
    app.state.stream_tasks = stream_tasks
    app.state.request_tasks = request_tasks
    app.state.stream_shutdown_grace_seconds = settings.stream_shutdown_grace_seconds
    app.state.shutting_down = False
    bearer = HTTPBearer(auto_error=False)

    @app.exception_handler(ServiceError)
    async def service_error(request, error):
        headers = {"Retry-After": str(error.retry_after)} if error.retry_after else None
        if error.status == 401:
            headers = {**(headers or {}), "WWW-Authenticate": "Bearer"}
        return JSONResponse(status_code=error.status, content={"detail": error.detail}, headers=headers)

    @app.middleware("http")
    async def boundaries(request: Request, call_next):
        # TLS is terminated by the deployment proxy. Apply a proxy body-size limit as well.
        if request.method in ("POST", "PUT", "PATCH"):
            length = request.headers.get("content-length", "0")
            limit = 12_000_000 if request.url.path == "/v1/works" else 262144
            if not length.isdigit() or int(length) > limit:
                return JSONResponse(status_code=413, content={"detail": "请求内容过大。"})
            body = await request.body()
            if len(body) > limit:
                return JSONResponse(status_code=413, content={"detail": "请求内容过大。"})
        response = await call_next(request)
        response.headers["Cache-Control"] = "no-store"
        response.headers["X-Content-Type-Options"] = "nosniff"
        return response

    async def account_id(credentials: HTTPAuthorizationCredentials | None = Depends(bearer)):
        if credentials is None:
            raise ServiceError(401, "请先登录。")
        account = sessions.verify(credentials.credentials)
        await run_in_threadpool(ledger.account, account)
        return account

    app.include_router(routes(Marketplace(ledger), account_id))

    @app.get("/health")
    async def health():
        return {"status": "ok"}

    @app.post("/v1/session")
    async def session(body: SessionRequest):
        claims = await identity.verify(body.identityToken, body.nonce)
        result = await run_in_threadpool(ledger.login, claims["sub"], settings.apple_bundle_id, hashlib.sha256(body.identityToken.encode()).hexdigest(), hashlib.sha256(body.nonce.encode()).hexdigest(), claims["exp"])
        return {**result, "token": sessions.issue(result["accountID"]), "tokensPerPoint": settings.tokens_per_point}

    @app.get("/v1/account")
    async def account(owner: str = Depends(account_id)):
        return {**(await run_in_threadpool(ledger.account, owner)), "tokensPerPoint": settings.tokens_per_point}

    @app.post("/v1/purchases")
    async def redeem(body: PurchaseRequest, owner: str = Depends(account_id)):
        # Apple's OCSP verification uses synchronous I/O; keep it off the ASGI event loop.
        receipt = await run_in_threadpool(purchases.verify, body.signedTransaction, owner)
        return await run_in_threadpool(ledger.redeem, owner, receipt.transaction_key, receipt.product_id, receipt.jws_hash)

    @app.post("/v1/app-store/notifications")
    async def app_store_notification(body: NotificationRequest):
        event = await run_in_threadpool(purchases.notification, body.signedPayload)
        if event is not None:
            await run_in_threadpool(ledger.purchase_notification, *event)
        return {"received": True}

    async def perform(owner, request_id, operation, payload, source, messages):
        budget = TokenBudget.for_request(settings, messages, source, operation, entity_query=payload.get("mode") == "entities-v1", capture=payload.get("glossaryCapture") is True)
        reservation = await run_in_threadpool(ledger.reserve_tokens, owner, request_id, operation, content_hash(operation, payload), budget)
        if reservation.cached is not None:
            return reservation.cached
        try:
            # Mark dispatched before upstream I/O; only a true shutdown can cancel this worker.
            await run_in_threadpool(ledger.dispatch, owner, request_id)
            if operation == "glossary":
                output = await model.terms(messages, max_tokens=reservation.max_tokens)
                result = list(output)
            else:
                output = await model.complete(messages, max_tokens=reservation.max_tokens)
                result = {"text": str(output)}
            usage = getattr(output, "usage", None)
            if not isinstance(usage, TokenUsage):
                raise DefiniteProviderFailure(502, "模型未返回可验证的用量记录，本次点数已退回。")
            await run_in_threadpool(ledger.complete, owner, request_id, result, usage)
            return result
        except DefiniteProviderFailure:
            await run_in_threadpool(ledger.refund, owner, request_id)
            raise
        except AmbiguousProviderFailure:
            await run_in_threadpool(ledger.uncertain, owner, request_id)
            raise
        except BaseException:
            # Includes app shutdown and a DB error after a successful upstream response.
            # A reservation not yet dispatched is safe to refund; sent work needs reconciliation.
            async def reconcile_shutdown():
                state = await run_in_threadpool(ledger.request_status, owner, request_id)
                if state["status"] == "reserved":
                    await run_in_threadpool(ledger.refund, owner, request_id)
                else:
                    await run_in_threadpool(ledger.uncertain, owner, request_id)
            await asyncio.shield(reconcile_shutdown())
            raise

    async def execute(owner, request_id, operation, payload, source, messages):
        if app.state.shutting_down:
            raise ServiceError(503, "服务正在重启，请稍后重试。", 5)
        # Client pause/cancel never owns the already-paid upstream model request.
        task = asyncio.create_task(perform(owner, request_id, operation, payload, source, messages), name="bookllm-model-request")
        request_tasks.add(task)
        def finished(completed):
            request_tasks.discard(completed)
            if not completed.cancelled():
                completed.exception()
        task.add_done_callback(finished)
        return await asyncio.shield(task)

    @app.post("/v1/translate/stream")
    async def translate_stream(body: TranslationRequest, owner: str = Depends(account_id)):
        if body.options.quality != Quality.fast or body.stage != Stage.translate:
            raise ServiceError(422, "实时翻译仅支持快速档的翻译阶段。")
        if app.state.shutting_down:
            raise ServiceError(503, "服务正在重启，请稍后重试。", 5)
        request_id = body.requestID
        messages = translation_messages(body)
        budget = TokenBudget.for_request(settings, messages, body.source, "translate", capture=body.glossaryCapture is True)
        reservation = await run_in_threadpool(ledger.reserve_tokens, owner, request_id, "translate", content_hash("translate", body.model_dump(mode="json")), budget)
        if reservation.cached is not None:
            cached = reservation.cached
            async def replay():
                yield sse_event({"delta": cached["text"]})
                yield sse_event({"done": True})
            return StreamingResponse(replay(), media_type="text/event-stream", headers={"X-Accel-Buffering": "no"})
        job = TranslationStreamJob(ledger, model, owner, request_id, messages, max_tokens=reservation.max_tokens)
        task = asyncio.create_task(job.run(), name="bookllm-translation-stream")
        stream_tasks.add(task)
        stream_jobs[task] = job
        def finished(completed):
            stream_tasks.discard(completed)
            stream_jobs.pop(completed, None)
            if not completed.cancelled():
                completed.exception()  # Consume unexpected task failures; durable ledger remains authoritative.
        task.add_done_callback(finished)
        try:
            # Preserve useful HTTP failures before the first real token, while cancellation of this
            # request cannot propagate into the application's upstream worker or its readiness Future.
            first_error = await asyncio.shield(job.ready)
            if first_error is not None:
                raise first_error
        except BaseException:
            job.detach()
            raise
        return StreamingResponse(job.events(), media_type="text/event-stream", headers={"X-Accel-Buffering": "no"})

    @app.post("/v1/translate")
    async def translate(body: TranslationRequest, owner: str = Depends(account_id)):
        return await execute(owner, body.requestID, "translate", body.model_dump(mode="json"), body.source, translation_messages(body))

    @app.post("/v1/glossary")
    async def glossary(body: GlossaryRequest, owner: str = Depends(account_id)):
        return await execute(owner, body.requestID, "glossary", body.model_dump(mode="json"), body.source, glossary_messages(body))

    @app.get("/v1/requests/{request_id}")
    async def request_status(request_id: str, owner: str = Depends(account_id)):
        return await run_in_threadpool(ledger.request_status, owner, request_id)

    return app
