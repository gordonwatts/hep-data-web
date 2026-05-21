from __future__ import annotations

import json
import secrets
import urllib.parse
import urllib.request

from django.conf import settings
from django.contrib.auth import get_user_model, login
from django.core.exceptions import PermissionDenied
from django.db import transaction
from django.shortcuts import resolve_url
from django.utils.http import url_has_allowed_host_and_scheme

from portal.models import ApprovalState, UserProfile, UserRole, get_or_create_profile_for_user

GITHUB_AUTHORIZE_URL = "https://github.com/login/oauth/authorize"
GITHUB_ACCESS_TOKEN_URL = "https://github.com/login/oauth/access_token"
GITHUB_USER_URL = "https://api.github.com/user"
GITHUB_EMAILS_URL = "https://api.github.com/user/emails"

SESSION_OAUTH_STATE_KEY = "github_oauth_state"
SESSION_OAUTH_NEXT_KEY = "github_oauth_next"
SESSION_APPROVED_LOGIN_KEY = "portal_github_login_approved"


def github_oauth_enabled() -> bool:
    return bool(settings.GITHUB_CLIENT_ID and settings.GITHUB_CLIENT_SECRET)


def safe_next_url(request, next_url: str | None) -> str | None:
    if not next_url:
        return None
    if url_has_allowed_host_and_scheme(
        next_url,
        allowed_hosts={request.get_host()},
        require_https=request.is_secure(),
    ):
        return next_url
    return None


def github_callback_url(request) -> str:
    public_base_url = getattr(settings, "PUBLIC_BASE_URL", "")
    callback_path = resolve_url("github-callback")
    if public_base_url:
        return f"{public_base_url.rstrip('/')}{callback_path}"
    return request.build_absolute_uri(callback_path)


def start_github_login(request, next_url: str | None = None) -> str:
    if not github_oauth_enabled():
        raise PermissionDenied("GitHub OAuth is not configured.")

    state = secrets.token_urlsafe(32)
    request.session[SESSION_OAUTH_STATE_KEY] = state
    request.session[SESSION_OAUTH_NEXT_KEY] = next_url or ""
    request.session.modified = True

    params = {
        "client_id": settings.GITHUB_CLIENT_ID,
        "redirect_uri": github_callback_url(request),
        "scope": "read:user user:email",
        "state": state,
    }
    return f"{GITHUB_AUTHORIZE_URL}?{urllib.parse.urlencode(params)}"


def exchange_code_for_token(*, code: str, redirect_uri: str) -> str:
    payload = urllib.parse.urlencode(
        {
            "client_id": settings.GITHUB_CLIENT_ID,
            "client_secret": settings.GITHUB_CLIENT_SECRET,
            "code": code,
            "redirect_uri": redirect_uri,
        }
    ).encode("utf-8")
    request = urllib.request.Request(
        GITHUB_ACCESS_TOKEN_URL,
        data=payload,
        headers={
            "Accept": "application/json",
            "User-Agent": "hep-data-web",
        },
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=10) as response:
        token_payload = json.loads(response.read().decode("utf-8"))
    access_token = token_payload.get("access_token")
    if not access_token:
        error = (
            token_payload.get("error_description") or token_payload.get("error") or "unknown error"
        )
        raise PermissionDenied(f"GitHub login failed: {error}")
    return str(access_token)


def _github_api_get(url: str, access_token: str) -> dict | list[dict]:
    request = urllib.request.Request(
        url,
        headers={
            "Accept": "application/vnd.github+json",
            "Authorization": f"Bearer {access_token}",
            "User-Agent": "hep-data-web",
            "X-GitHub-Api-Version": "2022-11-28",
        },
    )
    with urllib.request.urlopen(request, timeout=10) as response:
        return json.loads(response.read().decode("utf-8"))


def fetch_github_account(access_token: str) -> dict[str, str]:
    account = _github_api_get(GITHUB_USER_URL, access_token)
    if not isinstance(account, dict):
        raise PermissionDenied("GitHub login failed: invalid account payload")

    emails = _github_api_get(GITHUB_EMAILS_URL, access_token)
    primary_email = ""
    if isinstance(emails, list):
        for entry in emails:
            if isinstance(entry, dict) and entry.get("primary") and entry.get("email"):
                primary_email = str(entry["email"])
                break
        if not primary_email:
            for entry in emails:
                if isinstance(entry, dict) and entry.get("email"):
                    primary_email = str(entry["email"])
                    break

    return {
        "id": str(account.get("id") or ""),
        "login": str(account.get("login") or ""),
        "name": str(account.get("name") or ""),
        "avatar_url": str(account.get("avatar_url") or ""),
        "email": primary_email or str(account.get("email") or ""),
        "html_url": str(account.get("html_url") or ""),
    }


@transaction.atomic
def sync_github_user(account: dict[str, str]) -> UserProfile:
    github_id = account["id"]
    github_login = account["login"]
    github_email = account["email"]
    github_name = account["name"] or github_login or github_id
    github_avatar_url = account["avatar_url"]

    user_model = get_user_model()
    username = f"github-{github_id}"
    user, _created = user_model.objects.get_or_create(
        username=username,
        defaults={
            "email": github_email,
            "first_name": github_name,
        },
    )
    if github_email and user.email != github_email:
        user.email = github_email
    if github_name and user.first_name != github_name:
        user.first_name = github_name
    user.save(update_fields=["email", "first_name"])

    profile_defaults = {
        "github_login": github_login,
        "github_email": github_email,
        "github_avatar_url": github_avatar_url,
    }
    profile, created = UserProfile.objects.get_or_create(
        github_id=github_id,
        defaults={"user": user, **profile_defaults, "approval_state": ApprovalState.PENDING},
    )
    if created:
        profile.user = user
    else:
        changed = False
        for field, value in profile_defaults.items():
            if getattr(profile, field) != value:
                setattr(profile, field, value)
                changed = True
        if profile.user_id != user.id:
            profile.user = user
            changed = True
        if changed:
            profile.save(
                update_fields=[
                    "user",
                    "github_login",
                    "github_email",
                    "github_avatar_url",
                ]
            )
    if created:
        profile.save()
    return profile


def set_session_approval_state(request, *, approved: bool, next_url: str | None = None) -> None:
    request.session[SESSION_APPROVED_LOGIN_KEY] = approved
    if next_url is not None:
        request.session[SESSION_OAUTH_NEXT_KEY] = next_url
    request.session.modified = True


def login_user(
    request, profile: UserProfile, *, approved: bool, next_url: str | None = None
) -> None:
    login(request, profile.user, backend="django.contrib.auth.backends.ModelBackend")
    set_session_approval_state(request, approved=approved, next_url=next_url)


def profile_for_request_user(request):
    if request.user.is_authenticated:
        return get_or_create_profile_for_user(request.user)
    return None


def profile_has_app_access(profile: UserProfile | None, *, session_approved: bool) -> bool:
    if profile is None:
        return False
    return profile.approval_state == ApprovalState.APPROVED and session_approved


def profile_has_admin_access(
    profile: UserProfile | None, *, session_approved: bool, user_is_staff: bool
) -> bool:
    if user_is_staff:
        return True
    if profile is None:
        return False
    return (
        profile.role == UserRole.ADMIN
        and profile.approval_state == ApprovalState.APPROVED
        and session_approved
    )
