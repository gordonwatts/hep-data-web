"""Shared Django settings for hep_data_web."""

from __future__ import annotations

import os
from pathlib import Path
from urllib.parse import urlparse

BASE_DIR = Path(__file__).resolve().parent.parent.parent


def env(name: str, default: str = "") -> str:
    value = os.getenv(name)
    return default if value is None else value


def env_bool(name: str, default: bool = False) -> bool:
    value = os.getenv(name)
    if value is None:
        return default
    return value.lower() in {"1", "true", "yes", "on"}


def csv_env(name: str, default: str = "") -> list[str]:
    return [item.strip() for item in env(name, default).split(",") if item.strip()]


def database_settings() -> dict[str, dict[str, str]]:
    database_url = env("DATABASE_URL", f"sqlite:///{BASE_DIR / 'db.sqlite3'}")
    if database_url.startswith("postgres"):
        parsed_database_url = urlparse(database_url)
        return {
            "default": {
                "ENGINE": "django.db.backends.postgresql",
                "NAME": parsed_database_url.path.lstrip("/") or env("POSTGRES_DB", "hep_data_web"),
                "USER": parsed_database_url.username or env("POSTGRES_USER", "hep_data_web"),
                "PASSWORD": parsed_database_url.password
                or env("POSTGRES_PASSWORD", "hep_data_web"),
                "HOST": parsed_database_url.hostname or env("POSTGRES_HOST", "localhost"),
                "PORT": str(parsed_database_url.port or env("POSTGRES_PORT", "5432")),
            }
        }
    return {
        "default": {
            "ENGINE": "django.db.backends.sqlite3",
            "NAME": BASE_DIR / "db.sqlite3",
        }
    }


DEBUG = env_bool("DEBUG", False)
SECRET_KEY = env("SECRET_KEY", "django-insecure-change-me")
ALLOWED_HOSTS = csv_env("ALLOWED_HOSTS", "localhost,127.0.0.1")

INSTALLED_APPS = [
    "django.contrib.admin",
    "django.contrib.auth",
    "django.contrib.contenttypes",
    "django.contrib.sessions",
    "django.contrib.messages",
    "django.contrib.staticfiles",
    "portal",
]

MIDDLEWARE = [
    "django.middleware.security.SecurityMiddleware",
    "whitenoise.middleware.WhiteNoiseMiddleware",
    "django.contrib.sessions.middleware.SessionMiddleware",
    "django.middleware.common.CommonMiddleware",
    "django.middleware.csrf.CsrfViewMiddleware",
    "django.contrib.auth.middleware.AuthenticationMiddleware",
    "django.contrib.messages.middleware.MessageMiddleware",
    "django.middleware.clickjacking.XFrameOptionsMiddleware",
]

ROOT_URLCONF = "hep_data_web.urls"

TEMPLATES = [
    {
        "BACKEND": "django.template.backends.django.DjangoTemplates",
        "DIRS": [BASE_DIR / "templates"],
        "APP_DIRS": True,
        "OPTIONS": {
            "context_processors": [
                "django.template.context_processors.request",
                "django.contrib.auth.context_processors.auth",
                "django.contrib.messages.context_processors.messages",
            ],
        },
    }
]

WSGI_APPLICATION = "hep_data_web.wsgi.application"

DATABASES = database_settings()

AUTH_PASSWORD_VALIDATORS = [
    {"NAME": "django.contrib.auth.password_validation.UserAttributeSimilarityValidator"},
    {"NAME": "django.contrib.auth.password_validation.MinimumLengthValidator"},
    {"NAME": "django.contrib.auth.password_validation.CommonPasswordValidator"},
    {"NAME": "django.contrib.auth.password_validation.NumericPasswordValidator"},
]

LANGUAGE_CODE = "en-us"
TIME_ZONE = "UTC"
USE_I18N = True
USE_TZ = True

STATIC_URL = "/static/"
STATIC_ROOT = Path(env("STATIC_ROOT", str(BASE_DIR / "staticfiles")))
STATICFILES_DIRS = [BASE_DIR / "static"] if (BASE_DIR / "static").exists() else []
STATICFILES_STORAGE = "whitenoise.storage.CompressedManifestStaticFilesStorage"

MEDIA_URL = "/media/"
MEDIA_ROOT = Path(env("MEDIA_ROOT", str(BASE_DIR / "media")))
ARTIFACT_ROOT = Path(env("ARTIFACT_ROOT", str(MEDIA_ROOT / "artifacts")))

for path in (STATIC_ROOT, MEDIA_ROOT, ARTIFACT_ROOT):
    path.mkdir(parents=True, exist_ok=True)

DEFAULT_AUTO_FIELD = "django.db.models.BigAutoField"
LOGIN_REDIRECT_URL = "/"
LOGOUT_REDIRECT_URL = "/"
LOGIN_URL = "/accounts/login/"

EMAIL_BACKEND = env("EMAIL_BACKEND", "django.core.mail.backends.console.EmailBackend")
DEFAULT_FROM_EMAIL = env("DEFAULT_FROM_EMAIL", "hep-data-web@example.org")

CSRF_TRUSTED_ORIGINS = csv_env("CSRF_TRUSTED_ORIGINS")

GITHUB_CLIENT_ID = env("GITHUB_CLIENT_ID")
GITHUB_CLIENT_SECRET = env("GITHUB_CLIENT_SECRET")
GITHUB_ORG = env("GITHUB_ORG")
GITHUB_ADMIN_USERS = csv_env("GITHUB_ADMIN_USERS")

HEP_DATA_LLM_VERSION = env("HEP_DATA_LLM_VERSION")
HEP_DATA_LLM_HOME_DIR = env("HEP_DATA_LLM_HOME_DIR")
HEP_DATA_LLM_DOCKER_IMAGE = env("HEP_DATA_LLM_DOCKER_IMAGE", "hepdatallm-awkward:latest")
JOB_QUEUE_LIMIT = int(env("JOB_QUEUE_LIMIT", "20"))
JOB_POLL_INTERVAL_SECONDS = int(env("JOB_POLL_INTERVAL_SECONDS", "2"))
JOB_SOFT_TIMEOUT_SECONDS = int(env("JOB_SOFT_TIMEOUT_SECONDS", "1800"))
JOB_HARD_TIMEOUT_SECONDS = int(env("JOB_HARD_TIMEOUT_SECONDS", "2400"))
