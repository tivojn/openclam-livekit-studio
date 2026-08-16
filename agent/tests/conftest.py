import pytest


@pytest.fixture(autouse=True)
def livekit_constructor_environment(monkeypatch: pytest.MonkeyPatch) -> None:
    """Permit local construction of Inference clients without real credentials."""
    monkeypatch.setenv("LIVEKIT_URL", "wss://unit-test.invalid")
    monkeypatch.setenv("LIVEKIT_API_KEY", "unit-test-livekit-key")
    monkeypatch.setenv("LIVEKIT_API_SECRET", "unit-test-livekit-secret-32-bytes-plus")
