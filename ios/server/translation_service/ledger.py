"""Durable, serialized credit accounting; never hold transactions across network calls."""
from contextlib import contextmanager
import hashlib
import json
from pathlib import Path
import sqlite3
import time
import uuid


PRODUCTS = {
    "app.bookllm.credits.100": 100,
    "app.bookllm.credits.1000": 1000,
    "app.bookllm.byok.lifetime": 0,
}


class ServiceError(Exception):
    def __init__(self, status: int, detail: str, retry_after: int | None = None):
        self.status = status
        self.detail = detail
        self.retry_after = retry_after
        super().__init__(detail)


def content_hash(operation: str, payload: dict) -> str:
    canonical = json.dumps({"operation": operation, "payload": payload}, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(canonical.encode()).hexdigest()


def source_cost(source: str) -> int:
    # Unicode scalar values, including whitespace. Every executed stage is separately billed.
    return max(1, (len(source) + 999) // 1000)


class Ledger:
    def __init__(self, path: str, per_account_concurrency: int = 4, global_concurrency: int = 32):
        Path(path).parent.mkdir(parents=True, exist_ok=True)
        self.path = path
        self.per_account_concurrency = per_account_concurrency
        self.global_concurrency = global_concurrency
        with self.connection() as db:
            db.executescript("""
                PRAGMA journal_mode=WAL;
                CREATE TABLE IF NOT EXISTS accounts (
                    id TEXT PRIMARY KEY, apple_subject TEXT UNIQUE NOT NULL,
                    points INTEGER NOT NULL DEFAULT 0 CHECK(points >= 0),
                    own_api_unlocked INTEGER NOT NULL DEFAULT 0,
                    credit_debt INTEGER NOT NULL DEFAULT 0 CHECK(credit_debt >= 0),
                    created_at REAL NOT NULL
                );
                CREATE TABLE IF NOT EXISTS consumed_identities (
                    fingerprint TEXT PRIMARY KEY, nonce_hash TEXT UNIQUE NOT NULL,
                    expires_at REAL NOT NULL
                );
                CREATE TABLE IF NOT EXISTS purchases (
                    transaction_key TEXT PRIMARY KEY, account_id TEXT NOT NULL REFERENCES accounts(id),
                    product_id TEXT NOT NULL, points INTEGER NOT NULL,
                    jws_hash TEXT NOT NULL, created_at REAL NOT NULL
                );
                CREATE TABLE IF NOT EXISTS purchase_states (
                    transaction_key TEXT PRIMARY KEY, revoked INTEGER NOT NULL,
                    signed_at INTEGER NOT NULL, event_id TEXT UNIQUE NOT NULL
                );
                CREATE TABLE IF NOT EXISTS debt_events (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    account_id TEXT NOT NULL REFERENCES accounts(id), delta INTEGER NOT NULL,
                    kind TEXT NOT NULL, reference TEXT NOT NULL, created_at REAL NOT NULL
                );
                CREATE TABLE IF NOT EXISTS requests (
                    account_id TEXT NOT NULL REFERENCES accounts(id), request_id TEXT NOT NULL,
                    payload_hash TEXT NOT NULL, operation TEXT NOT NULL,
                    cost INTEGER NOT NULL CHECK(cost > 0),
                    status TEXT NOT NULL CHECK(status IN ('reserved','dispatched','uncertain','completed','refunded')),
                    response_json TEXT, attempts INTEGER NOT NULL DEFAULT 1,
                    created_at REAL NOT NULL, updated_at REAL NOT NULL,
                    PRIMARY KEY(account_id, request_id)
                );
                CREATE INDEX IF NOT EXISTS requests_status ON requests(status, account_id);
                CREATE TABLE IF NOT EXISTS credit_events (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    account_id TEXT NOT NULL REFERENCES accounts(id), delta INTEGER NOT NULL,
                    kind TEXT NOT NULL, reference TEXT NOT NULL, created_at REAL NOT NULL
                );
            """)

            columns = {r["name"] for r in db.execute("PRAGMA table_info(accounts)")}
            if "credit_debt" not in columns:
                db.execute("ALTER TABLE accounts ADD COLUMN credit_debt INTEGER NOT NULL DEFAULT 0 CHECK(credit_debt >= 0)")

    @contextmanager
    def connection(self):
        db = sqlite3.connect(self.path, timeout=10, isolation_level=None)
        db.row_factory = sqlite3.Row
        db.execute("PRAGMA foreign_keys=ON")
        db.execute("PRAGMA busy_timeout=10000")
        db.execute("PRAGMA synchronous=FULL")
        try:
            yield db
        finally:
            db.close()

    @contextmanager
    def atomic(self):
        with self.connection() as db:
            db.execute("BEGIN IMMEDIATE")
            try:
                yield db
                db.execute("COMMIT")
            except BaseException:
                db.execute("ROLLBACK")
                raise

    def _account(self, db, account_id):
        row = db.execute("SELECT * FROM accounts WHERE id=?", (account_id,)).fetchone()
        if row is None:
            raise ServiceError(401, "账户不存在，请重新登录。")
        return {"accountID": row["id"], "points": row["points"], "ownAPIUnlocked": bool(row["own_api_unlocked"]), "creditDebt": row["credit_debt"]}

    def account(self, account_id):
        with self.connection() as db:
            return self._account(db, account_id)

    def login(self, subject, bundle_id, fingerprint, nonce_hash, expires_at):
        account_id = str(uuid.uuid5(uuid.NAMESPACE_URL, f"bookllm:apple:{bundle_id}:{subject}"))
        with self.atomic() as db:
            db.execute("DELETE FROM consumed_identities WHERE expires_at < ?", (time.time(),))
            try:
                db.execute("INSERT INTO consumed_identities VALUES(?,?,?)", (fingerprint, nonce_hash, expires_at))
            except sqlite3.IntegrityError:
                raise ServiceError(401, "登录凭据已使用，请重新执行 Apple 登录。") from None
            db.execute("INSERT OR IGNORE INTO accounts(id,apple_subject,created_at) VALUES(?,?,?)", (account_id, subject, time.time()))
            return self._account(db, account_id)

    def _event(self, db, account_id, delta, kind, reference):
        db.execute("INSERT INTO credit_events(account_id,delta,kind,reference,created_at) VALUES(?,?,?,?,?)", (account_id, delta, kind, reference, time.time()))

    def redeem(self, account_id, transaction_key, product_id, jws_hash):
        if product_id not in PRODUCTS:
            raise ServiceError(400, "商品不支持。")
        with self.atomic() as db:
            self._account(db, account_id)
            row = db.execute("SELECT * FROM purchases WHERE transaction_key=?", (transaction_key,)).fetchone()
            if row is not None:
                if row["account_id"] != account_id or row["product_id"] != product_id:
                    raise ServiceError(403, "购买凭据属于其他账户。")
                return self._account(db, account_id)
            state = db.execute("SELECT revoked FROM purchase_states WHERE transaction_key=?", (transaction_key,)).fetchone()
            if state is not None and state["revoked"]:
                raise ServiceError(400, "此交易已退款或撤销，不能兑换旧的购买凭据。")
            points = PRODUCTS[product_id]
            db.execute("INSERT INTO purchases VALUES(?,?,?,?,?,?)", (transaction_key, account_id, product_id, points, jws_hash, time.time()))
            if points:
                self._credit(db, account_id, points, "purchase", transaction_key)
            else:
                db.execute("UPDATE accounts SET own_api_unlocked=1 WHERE id=?", (account_id,))
                self._event(db, account_id, 0, "unlock", transaction_key)
            return self._account(db, account_id)

    def reserve(self, account_id, request_id, operation, payload_hash, cost):
        """Return cached response, or None after exactly one committed reservation."""
        if cost <= 0:
            raise ValueError("Credit cost must be positive")
        with self.atomic() as db:
            account = self._account(db, account_id)
            row = db.execute("SELECT * FROM requests WHERE account_id=? AND request_id=?", (account_id, request_id)).fetchone()
            if row is not None:
                if row["payload_hash"] != payload_hash or row["operation"] != operation or row["cost"] != cost:
                    raise ServiceError(409, "requestID 已用于不同内容；请使用新的 requestID。")
                if row["status"] == "completed":
                    return json.loads(row["response_json"])
                if row["status"] in ("reserved", "dispatched"):
                    raise ServiceError(409, "此请求仍在后台处理中，请稍后使用原 requestID 重试；不会再次扣点。", 1)
                if row["status"] != "refunded":
                    raise ServiceError(409, "此请求结果待核对；重复提交不会再次扣点。可查看 /v1/requests/{requestID}，请勿更换 ID 重复提交。")
            active = db.execute("SELECT account_id,COUNT(*) AS n FROM requests WHERE status IN ('reserved','dispatched') GROUP BY account_id").fetchall()
            account_active = sum(r["n"] for r in active if r["account_id"] == account_id)
            global_active = sum(r["n"] for r in active)
            if account_active >= self.per_account_concurrency or global_active >= self.global_concurrency:
                raise ServiceError(429, "并发请求较多，请稍后重试。", 2)
            if account["creditDebt"]:
                raise ServiceError(402, "账户有购买退款后的点数差额，请补充点数或联系支持。")
            if account["points"] < cost:
                raise ServiceError(402, f"翻译点数不足；本次需 {cost} 点。")
            db.execute("UPDATE accounts SET points=points-? WHERE id=?", (cost, account_id))
            if row is None:
                db.execute("INSERT INTO requests(account_id,request_id,payload_hash,operation,cost,status,created_at,updated_at) VALUES(?,?,?,?,?,'reserved',?,?)", (account_id, request_id, payload_hash, operation, cost, time.time(), time.time()))
            else:
                db.execute("UPDATE requests SET status='reserved',attempts=attempts+1,updated_at=? WHERE account_id=? AND request_id=?", (time.time(), account_id, request_id))
            self._event(db, account_id, -cost, "reserve", request_id)
            return None

    def dispatch(self, account_id, request_id):
        with self.atomic() as db:
            updated = db.execute("UPDATE requests SET status='dispatched',updated_at=? WHERE account_id=? AND request_id=? AND status='reserved'", (time.time(), account_id, request_id)).rowcount
            if updated != 1:
                raise ServiceError(409, "请求状态已改变，请核对后再继续。")

    def complete(self, account_id, request_id, response):
        encoded = json.dumps(response, ensure_ascii=False, separators=(",", ":"))
        with self.atomic() as db:
            updated = db.execute("UPDATE requests SET status='completed',response_json=?,updated_at=? WHERE account_id=? AND request_id=? AND status IN ('dispatched','uncertain')", (encoded, time.time(), account_id, request_id)).rowcount
            if updated != 1:
                raise ServiceError(409, "请求结果无法提交，请联系支持核对该 requestID。")

    def uncertain(self, account_id, request_id):
        with self.atomic() as db:
            db.execute("UPDATE requests SET status='uncertain',updated_at=? WHERE account_id=? AND request_id=? AND status='dispatched'", (time.time(), account_id, request_id))

    def refund(self, account_id, request_id, *, allow_uncertain=False):
        with self.atomic() as db:
            row = db.execute("SELECT * FROM requests WHERE account_id=? AND request_id=?", (account_id, request_id)).fetchone()
            allowed = ("reserved", "dispatched", "uncertain") if allow_uncertain else ("reserved", "dispatched")
            if row is None or row["status"] not in allowed:
                return False
            db.execute("UPDATE requests SET status='refunded',updated_at=? WHERE account_id=? AND request_id=?", (time.time(), account_id, request_id))
            self._credit(db, account_id, row["cost"], "refund", request_id)
            return True

    def request_status(self, account_id, request_id):
        with self.connection() as db:
            row = db.execute("SELECT * FROM requests WHERE account_id=? AND request_id=?", (account_id, request_id)).fetchone()
            if row is None:
                raise ServiceError(404, "请求不存在。")
            result = {"requestID": request_id, "status": row["status"], "points": row["cost"], "updatedAt": row["updated_at"]}
            if row["response_json"]:
                result["result"] = json.loads(row["response_json"])
            return result


    def _debt_event(self, db, account_id, delta, kind, reference):
        db.execute("INSERT INTO debt_events(account_id,delta,kind,reference,created_at) VALUES(?,?,?,?,?)", (account_id, delta, kind, reference, time.time()))

    def _credit(self, db, account_id, amount, kind, reference):
        debt = db.execute("SELECT credit_debt FROM accounts WHERE id=?", (account_id,)).fetchone()["credit_debt"]
        repaid = min(debt, amount)
        points = amount - repaid
        db.execute("UPDATE accounts SET points=points+?,credit_debt=credit_debt-? WHERE id=?", (points, repaid, account_id))
        self._event(db, account_id, points, kind, reference)
        if repaid:
            self._debt_event(db, account_id, -repaid, kind, reference)

    def purchase_notification(self, transaction_key, revoked, signed_at, event_id):
        """Apply verified, ordered refund state, including a tombstone before redemption."""
        with self.atomic() as db:
            state = db.execute("SELECT * FROM purchase_states WHERE transaction_key=?", (transaction_key,)).fetchone()
            if state is not None and state["signed_at"] >= signed_at:
                return False
            if db.execute("SELECT 1 FROM purchase_states WHERE event_id=?", (event_id,)).fetchone():
                return False
            previously_revoked = bool(state["revoked"]) if state else False
            db.execute("INSERT INTO purchase_states VALUES(?,?,?,?) ON CONFLICT(transaction_key) DO UPDATE SET revoked=excluded.revoked,signed_at=excluded.signed_at,event_id=excluded.event_id", (transaction_key, int(revoked), signed_at, event_id))
            purchase = db.execute("SELECT * FROM purchases WHERE transaction_key=?", (transaction_key,)).fetchone()
            if purchase is None or previously_revoked == revoked:
                return True
            owner = purchase["account_id"]
            amount = purchase["points"]
            if amount:
                if revoked:
                    available = self._account(db, owner)["points"]
                    removed = min(available, amount)
                    debt = amount - removed
                    db.execute("UPDATE accounts SET points=points-?,credit_debt=credit_debt+? WHERE id=?", (removed, debt, owner))
                    self._event(db, owner, -removed, "purchase_revoked", transaction_key)
                    if debt:
                        self._debt_event(db, owner, debt, "purchase_revoked", transaction_key)
                else:
                    self._credit(db, owner, amount, "refund_reversed", transaction_key)
            else:
                active = db.execute("SELECT 1 FROM purchases p LEFT JOIN purchase_states s ON p.transaction_key=s.transaction_key WHERE p.account_id=? AND p.product_id='app.bookllm.byok.lifetime' AND COALESCE(s.revoked,0)=0 LIMIT 1", (owner,)).fetchone()
                db.execute("UPDATE accounts SET own_api_unlocked=? WHERE id=?", (int(active is not None), owner))
                self._event(db, owner, 0, "unlock_revoked" if revoked else "unlock_restored", transaction_key)
            return True
