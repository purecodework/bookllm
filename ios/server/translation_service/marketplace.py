"""Private-by-link translated works with atomic, idempotent credit purchases."""
import base64
import hashlib
import html
import json
import time
import uuid
from typing import Annotated

from pydantic import BaseModel, ConfigDict, Field, StrictBool, StrictInt, field_validator
from fastapi import APIRouter, Depends
from fastapi.responses import HTMLResponse
from starlette.concurrency import run_in_threadpool
from .ledger import ServiceError


class Publication(BaseModel):
    model_config = ConfigDict(extra="forbid", str_strip_whitespace=True)
    publicationID: str
    title: str = Field(min_length=1, max_length=200)
    text: str = Field(min_length=1, max_length=2_000_000)
    targetLanguage: str = Field(min_length=1, max_length=80)
    styleName: str = Field(min_length=1, max_length=100)
    price: Annotated[StrictInt, Field(ge=1, le=100_000)]
    rightsConfirmed: StrictBool
    coverBase64: str | None = Field(default=None, max_length=2_800_000)

    @field_validator("publicationID")
    @classmethod
    def valid_id(cls, value):
        try:
            return str(uuid.UUID(value))
        except ValueError:
            raise ValueError("Invalid publication UUID") from None

    @field_validator("coverBase64")
    @classmethod
    def cover(cls, value):
        if value is None:
            return None
        try:
            data = base64.b64decode(value, validate=True)
        except ValueError:
            raise ValueError("Invalid cover") from None
        if len(data) > 2_000_000 or not (data.startswith(b"\x89PNG\r\n\x1a\n") or data.startswith(b"\xff\xd8\xff")):
            raise ValueError("Cover must be a PNG or JPEG under 2 MB")
        return value


class Marketplace:
    def __init__(self, ledger):
        self.ledger = ledger
        with ledger.connection() as db:
            db.executescript("""
                CREATE TABLE IF NOT EXISTS works(
                    id TEXT PRIMARY KEY, owner TEXT NOT NULL REFERENCES accounts(id),
                    publication_id TEXT NOT NULL, payload_hash TEXT NOT NULL,
                    title TEXT NOT NULL, text TEXT NOT NULL, target_language TEXT NOT NULL,
                    style_name TEXT NOT NULL, price INTEGER NOT NULL CHECK(price>0),
                    cover TEXT, created_at REAL NOT NULL, UNIQUE(owner, publication_id)
                );
                CREATE TABLE IF NOT EXISTS work_purchases(
                    work_id TEXT NOT NULL REFERENCES works(id), buyer TEXT NOT NULL REFERENCES accounts(id),
                    price INTEGER NOT NULL, created_at REAL NOT NULL, PRIMARY KEY(work_id,buyer)
                );
            """)

    @staticmethod
    def identifier(value):
        # Opaque UUIDs: no sequential catalogue and no title-based lookup.
        try:
            return str(uuid.UUID(value))
        except ValueError:
            raise ServiceError(404, "译作不存在。") from None

    def _row(self, db, value):
        row = db.execute("SELECT * FROM works WHERE id=?", (self.identifier(value),)).fetchone()
        if row is None:
            raise ServiceError(404, "译作不存在。")
        return row

    def _metadata(self, db, row, owner=None):
        purchased = owner is not None and bool(db.execute("SELECT 1 FROM work_purchases WHERE work_id=? AND buyer=?", (row["id"], owner)).fetchone())
        return {"id": row["id"], "title": row["title"], "targetLanguage": row["target_language"], "styleName": row["style_name"], "price": row["price"], "isOwner": row["owner"] == owner, "purchased": purchased}

    def publish(self, owner, body):
        if not body.rightsConfirmed:
            raise ServiceError(422, "请确认拥有原作翻译和译作分享的权利。")
        payload = body.model_dump(mode="json")
        digest = hashlib.sha256(json.dumps(payload, sort_keys=True, ensure_ascii=False).encode()).hexdigest()
        with self.ledger.atomic() as db:
            self.ledger._account(db, owner)
            row = db.execute("SELECT * FROM works WHERE owner=? AND publication_id=?", (owner, body.publicationID)).fetchone()
            if row is not None:
                if row["payload_hash"] != digest:
                    raise ServiceError(409, "此发布已完成；修改内容需要重新发布。")
                return self._metadata(db, row, owner)
            work_id = str(uuid.uuid4())
            db.execute("INSERT INTO works VALUES(?,?,?,?,?,?,?,?,?,?,?)", (work_id, owner, body.publicationID, digest, body.title, body.text, body.targetLanguage, body.styleName, body.price, body.coverBase64, time.time()))
            return self._metadata(db, self._row(db, work_id), owner)

    def metadata(self, work_id, owner=None):
        with self.ledger.connection() as db:
            return self._metadata(db, self._row(db, work_id), owner)

    def purchase(self, work_id, owner):
        with self.ledger.atomic() as db:
            account = self.ledger._account(db, owner)
            row = self._row(db, work_id)
            if row["owner"] == owner:
                raise ServiceError(409, "这是你发布的译作，无需购买。")
            if db.execute("SELECT 1 FROM work_purchases WHERE work_id=? AND buyer=?", (row["id"], owner)).fetchone():
                return {"work": self._metadata(db, row, owner), "account": account, "charged": 0}
            if account["points"] < row["price"]:
                raise ServiceError(402, "点数不足，充值后可购买译作。")
            db.execute("UPDATE accounts SET points=points-? WHERE id=?", (row["price"], owner))
            self.ledger._event(db, owner, -row["price"], "work_purchase", row["id"])
            # Existing Apple refund debt is repaid before the seller receives spendable points.
            self.ledger._credit(db, row["owner"], row["price"], "work_income", row["id"] + ":" + owner)
            db.execute("INSERT INTO work_purchases VALUES(?,?,?,?)", (row["id"], owner, row["price"], time.time()))
            return {"work": self._metadata(db, row, owner), "account": self.ledger._account(db, owner), "charged": row["price"]}

    def content(self, work_id, owner):
        with self.ledger.connection() as db:
            row = self._row(db, work_id)
            metadata = self._metadata(db, row, owner)
            if not (metadata["isOwner"] or metadata["purchased"]):
                raise ServiceError(403, "购买后可阅读此译作。")
            return {**metadata, "text": row["text"], "coverBase64": row["cover"]}


def routes(market, account_id):
    router = APIRouter()

    @router.post("/v1/works")
    async def publish(body: Publication, owner: str = Depends(account_id)):
        return await run_in_threadpool(market.publish, owner, body)

    @router.get("/v1/works/{work_id}")
    async def metadata(work_id: str, owner: str = Depends(account_id)):
        return await run_in_threadpool(market.metadata, work_id, owner)

    @router.post("/v1/works/{work_id}/purchase")
    async def purchase(work_id: str, owner: str = Depends(account_id)):
        return await run_in_threadpool(market.purchase, work_id, owner)

    @router.get("/v1/works/{work_id}/content")
    async def content(work_id: str, owner: str = Depends(account_id)):
        return await run_in_threadpool(market.content, work_id, owner)

    @router.get("/w/{work_id}", response_class=HTMLResponse)
    async def landing(work_id: str):
        value = await run_in_threadpool(market.metadata, work_id)
        title = html.escape(value["title"])
        identifier = value["id"]
        return HTMLResponse(f'''<!doctype html><html lang="zh"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>{title} · 译间</title><style>body{{background:#f5f2eb;color:#262823;font:16px system-ui;margin:0;padding:12vh 24px;max-width:500px;margin:auto}}h1{{font:32px Georgia,serif}}a{{display:block;padding:16px;background:#262823;color:white;border-radius:24px;text-align:center;text-decoration:none}}code{{overflow-wrap:anywhere}}p{{line-height:1.8}}</style><p>译间 · 译作</p><h1>{title}</h1><p>{value['price']} 点 · {html.escape(value['targetLanguage'])}</p><a href="bookllm://work/{identifier}">在译间打开</a><p>也可在译间书架输入作品 ID：<br><code>{identifier}</code></p></html>''', headers={"Content-Security-Policy": "default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; frame-ancestors 'none'"})

    return router
