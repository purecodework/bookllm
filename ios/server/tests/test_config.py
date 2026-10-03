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
