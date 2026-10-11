import pytest
from translation_service.config import Settings


def test_release_startup_requires_credentials(monkeypatch):
    monkeypatch.delenv("SESSION_SECRET", raising=False)
    with pytest.raises(RuntimeError, match="SESSION_SECRET"):
        Settings.from_env()


def test_no_local_storekit_environment_can_be_enabled(monkeypatch, tmp_path):
    root = tmp_path / "AppleRoot.cer"
    root.write_bytes(b"unit-test-certificate-path-only")
    monkeypatch.setenv("SESSION_SECRET", "unit-test-secret-" * 4)
    monkeypatch.setenv("APPLE_ROOT_CERTIFICATES", str(root))
    monkeypatch.setenv("APPLE_ENVIRONMENT", "Xcode")
    with pytest.raises(RuntimeError, match="Only Apple Production or Sandbox"):
        Settings.from_env()


@pytest.mark.parametrize("name,value,match", [
    ("TOKENS_PER_POINT", "0", "TOKENS_PER_POINT"),
    ("MAX_OUTPUT_TOKENS", "10000", "Output token limits"),
    ("MINIMUM_OUTPUT_TOKENS", "1", "Output token limits"),
    ("MINIMUM_OUTPUT_TOKENS", "8193", "Output token limits"),
])
def test_invalid_billing_limits_fail_release_startup(monkeypatch, tmp_path, name, value, match):
    root = tmp_path / "AppleRoot.cer"
    root.write_bytes(b"test-path-only")
    for key, setting in {"SESSION_SECRET": "unit-test-secret-" * 4, "APPLE_ROOT_CERTIFICATES": str(root), "APPLE_ENVIRONMENT": "Sandbox", "APPLE_BUNDLE_ID": "app.bookllm.ios", "APPLE_APP_ID": "1234", "DEEPSEEK_API_KEY": "test-key-only", "TOKENS_PER_POINT": "1000", "MAX_OUTPUT_TOKENS": "8192", "MINIMUM_OUTPUT_TOKENS": "128"}.items():
        monkeypatch.setenv(key, setting)
    monkeypatch.setenv(name, value)
    with pytest.raises(RuntimeError, match=match):
        Settings.from_env()
