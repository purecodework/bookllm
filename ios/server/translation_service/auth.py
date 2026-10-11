import asyncio
import hashlib
import hmac
import time
import uuid

import httpx
import jwt
from jwt import PyJWK

from .config import Settings
from .ledger import ServiceError


APPLE_ISSUER = "https://appleid.apple.com"
APPLE_KEYS_URL = "https://appleid.apple.com/auth/keys"
SESSION_ISSUER = "bookllm-cloud"
SESSION_AUDIENCE = "bookllm-api"


class AppleIdentityVerifier:
    def __init__(self, client: httpx.AsyncClient, bundle_id: str):
        self.client = client
        self.bundle_id = bundle_id
        self.keys = {}
        self.last_refresh = 0.0
        self.lock = asyncio.Lock()

    async def _key(self, kid):
        async with self.lock:
            now = time.monotonic()
            if not self.keys or now - self.last_refresh > 3600 or (kid not in self.keys and now - self.last_refresh > 60):
                try:
                    response = await self.client.get(APPLE_KEYS_URL, timeout=10)
                    response.raise_for_status()
                    entries = response.json()["keys"]
                    new_keys = {item["kid"]: PyJWK.from_dict(item, algorithm="RS256").key for item in entries if item.get("kty") == "RSA" and item.get("alg") == "RS256"}
                    if not new_keys:
                        raise ValueError("No trusted signing keys")
                    self.keys = new_keys
                    self.last_refresh = now
                except (httpx.HTTPError, ValueError, KeyError, jwt.PyJWTError):
                    raise ServiceError(503, "Apple 登录验证暂不可用，请稍后重试。", 5) from None
            key = self.keys.get(kid)
            if key is None:
                raise ServiceError(401, "Apple 登录签名无效。")
            return key

    async def verify(self, identity_token: str, raw_nonce: str):
        try:
            header = jwt.get_unverified_header(identity_token)
            if header.get("alg") != "RS256" or not isinstance(header.get("kid"), str) or len(header["kid"]) > 256:
                raise jwt.InvalidTokenError()
            key = await self._key(header["kid"])
            claims = jwt.decode(
                identity_token, key, algorithms=["RS256"], audience=self.bundle_id,
                issuer=APPLE_ISSUER, leeway=30,
                options={"require": ["iss", "aud", "sub", "exp", "iat", "nonce"]},
            )
            now = time.time()
            if not isinstance(claims["sub"], str) or not 1 <= len(claims["sub"]) <= 256:
                raise jwt.InvalidTokenError()
            if not isinstance(claims["nonce"], str) or not isinstance(claims["iat"], (int, float)) or not isinstance(claims["exp"], (int, float)):
                raise jwt.InvalidTokenError()
            # An identity token is a fresh login proof, rather than a reusable session.
            if claims["iat"] < now - 600 or claims["iat"] > now + 30 or claims["exp"] <= now:
                raise jwt.InvalidTokenError()
            expected = hashlib.sha256(raw_nonce.encode()).hexdigest()
            if not hmac.compare_digest(claims["nonce"], expected):
                raise jwt.InvalidTokenError()
            return claims
        except (jwt.PyJWTError, KeyError, TypeError, ValueError):
            raise ServiceError(401, "Apple 登录凭据或 nonce 无效，请重新登录。") from None


class Sessions:
    def __init__(self, settings: Settings):
        self.secret = settings.session_secret
        self.ttl = settings.session_ttl_seconds

    def issue(self, account_id):
        now = int(time.time())
        return jwt.encode({"sub": account_id, "iss": SESSION_ISSUER, "aud": SESSION_AUDIENCE, "iat": now, "exp": now + self.ttl, "jti": str(uuid.uuid4())}, self.secret, algorithm="HS256")

    def verify(self, token):
        try:
            claims = jwt.decode(token, self.secret, algorithms=["HS256"], issuer=SESSION_ISSUER, audience=SESSION_AUDIENCE, options={"require": ["sub", "iss", "aud", "iat", "exp", "jti"]})
            return str(uuid.UUID(claims["sub"]))
        except (jwt.PyJWTError, KeyError, ValueError, TypeError):
            raise ServiceError(401, "登录已失效，请重新登录。") from None
