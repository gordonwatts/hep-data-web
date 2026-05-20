import importlib

from hep_data_web.env import load_env_file
from hep_data_web.settings import base


def test_csv_env_parses_and_trims(monkeypatch):
    monkeypatch.setenv("TEST_LIST", "alpha, beta , ,gamma")
    assert base.csv_env("TEST_LIST") == ["alpha", "beta", "gamma"]


def test_load_env_file_populates_missing_values(tmp_path, monkeypatch):
    env_file = tmp_path / ".env"
    env_file.write_text("ALPHA=one\nBETA='two'\n# comment\n", encoding="utf-8")

    monkeypatch.delenv("ALPHA", raising=False)
    monkeypatch.delenv("BETA", raising=False)

    load_env_file(env_file)

    assert base.os.environ["ALPHA"] == "one"
    assert base.os.environ["BETA"] == "two"


def test_load_env_file_does_not_overwrite_existing_values(tmp_path, monkeypatch):
    env_file = tmp_path / ".env"
    env_file.write_text("ALPHA=from-file\n", encoding="utf-8")

    monkeypatch.setenv("ALPHA", "from-env")
    load_env_file(env_file)

    assert base.os.environ["ALPHA"] == "from-env"


def test_database_settings_parses_postgres_url(monkeypatch):
    monkeypatch.setenv(
        "DATABASE_URL",
        "postgresql://alice:secret@db.example.com:5433/analysis",
    )
    settings = base.database_settings()
    assert settings["default"]["ENGINE"] == "django.db.backends.postgresql"
    assert settings["default"]["NAME"] == "analysis"
    assert settings["default"]["USER"] == "alice"
    assert settings["default"]["PASSWORD"] == "secret"
    assert settings["default"]["HOST"] == "db.example.com"
    assert settings["default"]["PORT"] == "5433"


def test_dev_settings_force_debug_true():
    dev = importlib.import_module("hep_data_web.settings.dev")
    assert dev.DEBUG is True


def test_base_settings_expose_docker_execution_overrides(monkeypatch):
    monkeypatch.setenv("HEP_DATA_LLM_HOME_DIR", "/tmp/home")
    monkeypatch.setenv("HEP_DATA_LLM_MODEL", "gpt-4o")
    monkeypatch.setenv("HEP_DATA_LLM_REPAIR_CYCLES", "12")
    monkeypatch.setenv("HEP_DATA_LLM_SERVICEX_AWKWARD_DOCKER_IMAGE", "example/image:latest")
    module = importlib.reload(base)
    assert module.HEP_DATA_LLM_HOME_DIR == "/tmp/home"
    assert module.HEP_DATA_LLM_MODEL == "gpt-4o"
    assert module.HEP_DATA_LLM_REPAIR_CYCLES == 12
    assert module.HEP_DATA_LLM_SERVICEX_AWKWARD_DOCKER_IMAGE == "example/image:latest"
    monkeypatch.delenv("HEP_DATA_LLM_HOME_DIR", raising=False)
    monkeypatch.delenv("HEP_DATA_LLM_MODEL", raising=False)
    monkeypatch.delenv("HEP_DATA_LLM_REPAIR_CYCLES", raising=False)
    monkeypatch.delenv("HEP_DATA_LLM_SERVICEX_AWKWARD_DOCKER_IMAGE", raising=False)
    importlib.reload(base)
