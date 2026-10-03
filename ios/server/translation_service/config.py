from dataclasses import dataclass
import os
from pathlib import Path
from urllib.parse import urlparse


@dataclass(frozen=True)
class Settings:
    database_path: str
    session_secret: str
    apple_bundle_id: str
    apple_app_id: int
    apple_environment: str
    apple_root_paths: tuple[str, ...]
    deepseek_api_key: str
    deepseek_base_url: str = "https://api.deepseek.com"
    deepseek_model: str = "deepseek-chat"
    session_ttl_seconds: int = 604800
    per_account_concurrency: int = 4
    global_concurrency: int = 32
    request_timeout_seconds: float = 180
    stream_shutdown_grace_seconds: float = 10

    @classmethod
    def from_env(cls):
        def required(name):
            value = os.environ.get(name, "").strip()
            if not value:
                raise RuntimeError(f"Required environment variable {name} is missing")
            return value

        secret = required("SESSION_SECRET")
        if len(secret.encode()) < 32:
            raise RuntimeError("SESSION_SECRET must contain at least 32 random bytes")
        roots = tuple(p.strip() for p in required("APPLE_ROOT_CERTIFICATES").split(",") if p.strip())
        if not roots:
            raise RuntimeError("At least one trusted Apple root certificate is required")
        for root in roots:
            if not Path(root).is_file():
                raise RuntimeError(f"Apple root certificate does not exist: {root}")
        environment = os.environ.get("APPLE_ENVIRONMENT", "Production")
        if environment not in ("Production", "Sandbox"):
            raise RuntimeError("Only Apple Production or Sandbox verification is permitted")
        base = os.environ.get("DEEPSEEK_BASE_URL", "https://api.deepseek.com").rstrip("/")
        if urlparse(base).scheme != "https" or not urlparse(base).hostname:
            raise RuntimeError("DEEPSEEK_BASE_URL must use HTTPS")
        settings = cls(
            database_path=os.environ.get("DATABASE_PATH", "./data/bookllm.sqlite3"),
            session_secret=secret,
            apple_bundle_id=required("APPLE_BUNDLE_ID"),
            apple_app_id=int(required("APPLE_APP_ID")),
            apple_environment=environment,
            apple_root_paths=roots,
            deepseek_api_key=required("DEEPSEEK_API_KEY"),
            deepseek_base_url=base,
            deepseek_model=os.environ.get("DEEPSEEK_MODEL", "deepseek-chat"),
            session_ttl_seconds=int(os.environ.get("SESSION_TTL_SECONDS", "604800")),
            per_account_concurrency=int(os.environ.get("PER_ACCOUNT_CONCURRENCY", "4")),
            global_concurrency=int(os.environ.get("GLOBAL_CONCURRENCY", "32")),
            request_timeout_seconds=float(os.environ.get("REQUEST_TIMEOUT_SECONDS", "180")),
            stream_shutdown_grace_seconds=float(os.environ.get("STREAM_SHUTDOWN_GRACE_SECONDS", "10")),
        )
        if not 300 <= settings.session_ttl_seconds <= 604800:
            raise RuntimeError("SESSION_TTL_SECONDS must be 300–604800")
        if not 1 <= settings.per_account_concurrency <= settings.global_concurrency <= 256:
            raise RuntimeError("Invalid account/global concurrency limits")
        if not 0 <= settings.stream_shutdown_grace_seconds <= 300:
            raise RuntimeError("STREAM_SHUTDOWN_GRACE_SECONDS must be 0–300")
        if settings.apple_app_id <= 0 or not 10 <= settings.request_timeout_seconds <= 300:
            raise RuntimeError("Invalid app ID or request timeout")
        return settings
