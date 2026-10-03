import asyncio
from contextlib import asynccontextmanager
import hashlib
import json

import httpx
from fastapi import Depends, FastAPI, Request
from fastapi.responses import JSONResponse, StreamingResponse
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from starlette.concurrency import run_in_threadpool

from .auth import AppleIdentityVerifier, Sessions
from .config import Settings
from .ledger import Ledger, ServiceError, content_hash, source_cost
from .models import GlossaryRequest, NotificationRequest, PurchaseRequest, Quality, SessionRequest, Stage, TranslationRequest
from .prompts import glossary_messages, translation_messages
from .provider import AmbiguousProviderFailure, DeepSeek, DefiniteProviderFailure
from .purchases import ApplePurchaseVerifier


def create_app(settings: Settings, *, identity_verifier=None, purchase_verifier=None, provider=None):
    # Dependency injection is only a Python construction API for tests, never an HTTP/env bypass.
    ledger = Ledger(settings.database_path, settings.per_account_concurrency, settings.global_concurrency)
    sessions = Sessions(settings)
    client = httpx.AsyncClient(follow_redirects=False, limits=httpx.Limits(max_connections=settings.global_concurrency + 4, max_keepalive_connections=settings.global_concurrency))
    identity = identity_verifier or AppleIdentityVerifier(client, settings.apple_bundle_id)
    purchases = purchase_verifier or ApplePurchaseVerifier(settings)
    model = provider or DeepSeek(settings, client)

    @asynccontextmanager
    async def lifespan(app):
        yield
        await client.aclose()

    app = FastAPI(title="BookLLM Cloud", version="1.0.0", lifespan=lifespan, docs_url=None, redoc_url=None)
    app.state.ledger = ledger
    app.state.sessions = sessions
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
            if not length.isdigit() or int(length) > 262144:
                return JSONResponse(status_code=413, content={"detail": "请求内容过大。"})
            body = await request.body()
            if len(body) > 262144:
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

    @app.get("/health")
    async def health():
        return {"status": "ok"}

    @app.post("/v1/session")
    async def session(body: SessionRequest):
        claims = await identity.verify(body.identityToken, body.nonce)
        result = await run_in_threadpool(ledger.login, claims["sub"], settings.apple_bundle_id, hashlib.sha256(body.identityToken.encode()).hexdigest(), hashlib.sha256(body.nonce.encode()).hexdigest(), claims["exp"])
        return {**result, "token": sessions.issue(result["accountID"])}

    @app.get("/v1/account")
    async def account(owner: str = Depends(account_id)):
        return await run_in_threadpool(ledger.account, owner)

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

    async def execute(owner, request_id, operation, payload, source, messages):
        reservation = await run_in_threadpool(ledger.reserve, owner, request_id, operation, content_hash(operation, payload), source_cost(source))
        if reservation is not None:
            return reservation
        # Mark dispatched before starting any upstream I/O. A crash afterward needs reconciliation.
        await run_in_threadpool(ledger.dispatch, owner, request_id)
        try:
            if operation == "glossary":
                result = await model.terms(messages)
            else:
                result = {"text": await model.complete(messages)}
            await run_in_threadpool(ledger.complete, owner, request_id, result)
            return result
        except DefiniteProviderFailure:
            await run_in_threadpool(ledger.refund, owner, request_id)
            raise
        except AmbiguousProviderFailure:
            await run_in_threadpool(ledger.uncertain, owner, request_id)
            raise
        except BaseException:
            # Includes cancelled/disconnected requests and a DB error after a successful upstream response.
            # No automatic refund: the model may already have done the work.
            await asyncio.shield(run_in_threadpool(ledger.uncertain, owner, request_id))
            raise

    def event(data):
        return "data:" + json.dumps(data, ensure_ascii=False, separators=(",", ":")) + "\n\n"

    @app.post("/v1/translate/stream")
    async def translate_stream(body: TranslationRequest, owner: str = Depends(account_id)):
        if body.options.quality != Quality.fast or body.stage != Stage.translate:
            raise ServiceError(422, "实时翻译仅支持快速档的翻译阶段。")
        request_id = body.requestID
        cached = await run_in_threadpool(ledger.reserve, owner, request_id, "translate", content_hash("translate", body.model_dump(mode="json")), source_cost(body.source))
        if cached is not None:
            async def replay():
                yield event({"delta": cached["text"]})
                yield event({"done": True})
            return StreamingResponse(replay(), media_type="text/event-stream", headers={"X-Accel-Buffering": "no"})
        await run_in_threadpool(ledger.dispatch, owner, request_id)
        upstream = model.stream(translation_messages(body))
        try:
            # Prime the true upstream stream so connection/HTTP failures retain useful HTTP statuses.
            first = await anext(upstream)
        except DefiniteProviderFailure:
            await run_in_threadpool(ledger.refund, owner, request_id)
            await upstream.aclose()
            raise
        except AmbiguousProviderFailure:
            await run_in_threadpool(ledger.uncertain, owner, request_id)
            await upstream.aclose()
            raise
        except BaseException:
            await asyncio.shield(run_in_threadpool(ledger.uncertain, owner, request_id))
            await upstream.aclose()
            raise

        async def stream_output():
            fragments = [first]
            try:
                yield event({"delta": first})
                async for fragment in upstream:
                    fragments.append(fragment)
                    yield event({"delta": fragment})
                # Upstream stream() only exits successfully after a complete stop marker.
                text = "".join(fragments)
                await run_in_threadpool(ledger.complete, owner, request_id, {"text": text})
                yield event({"done": True})
            except DefiniteProviderFailure as error:
                await run_in_threadpool(ledger.refund, owner, request_id)
                yield event({"error": error.detail, "status": error.status, "retryAfter": error.retry_after})
            except AmbiguousProviderFailure as error:
                await run_in_threadpool(ledger.uncertain, owner, request_id)
                yield event({"error": error.detail, "status": error.status, "retryAfter": error.retry_after})
            except BaseException:
                await asyncio.shield(run_in_threadpool(ledger.uncertain, owner, request_id))
                raise
            finally:
                await upstream.aclose()
        return StreamingResponse(stream_output(), media_type="text/event-stream", headers={"X-Accel-Buffering": "no"})

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
