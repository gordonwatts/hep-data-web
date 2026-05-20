from __future__ import annotations

from django.shortcuts import redirect
from django.urls import reverse

from portal.auth import (
    SESSION_APPROVED_LOGIN_KEY,
    profile_has_app_access,
)
from portal.models import ApprovalState, get_or_create_profile_for_user


class ApprovalGateMiddleware:
    allowed_prefixes = (
        "/accounts/login/",
        "/accounts/logout/",
        "/accounts/status/",
        "/auth/github/login/",
        "/auth/github/callback/",
        "/static/",
        "/media/",
    )

    def __init__(self, get_response):
        self.get_response = get_response

    def __call__(self, request):
        if not request.user.is_authenticated or request.user.is_staff:
            return self.get_response(request)

        path = request.path
        if path.startswith(self.allowed_prefixes):
            return self.get_response(request)

        profile = get_or_create_profile_for_user(request.user)
        session_approved = bool(request.session.get(SESSION_APPROVED_LOGIN_KEY))

        if profile_has_app_access(profile, session_approved=session_approved):
            return self.get_response(request)

        if profile.approval_state == ApprovalState.PENDING:
            return redirect(reverse("auth-status"))
        if profile.approval_state == ApprovalState.REJECTED:
            return redirect(reverse("auth-status"))
        return redirect(reverse("auth-status"))
