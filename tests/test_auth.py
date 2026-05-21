from unittest.mock import patch
import urllib.error

from django.contrib.auth import get_user_model
from django.test import Client, TestCase, override_settings
from django.urls import reverse

from portal.auth import (
    SESSION_APPROVED_LOGIN_KEY,
    SESSION_OAUTH_NEXT_KEY,
    SESSION_OAUTH_STATE_KEY,
)
from portal.models import ApprovalState, UserProfile, get_or_create_profile_for_user


class AuthFlowTests(TestCase):
    def setUp(self):
        user_model = get_user_model()
        self.admin_user = user_model.objects.create_user(
            username="admin",
            email="admin@example.org",
            password="secret",
            is_staff=True,
        )

    def _force_pending_login(self, user):
        profile = get_or_create_profile_for_user(user)
        profile.approval_state = ApprovalState.PENDING
        profile.save(update_fields=["approval_state"])
        self.client.force_login(user)
        session = self.client.session
        session[SESSION_APPROVED_LOGIN_KEY] = False
        session.save()

    def _force_approved_login(self, user):
        profile = get_or_create_profile_for_user(user)
        profile.approval_state = ApprovalState.APPROVED
        profile.save(update_fields=["approval_state"])
        self.client.force_login(user)
        session = self.client.session
        session[SESSION_APPROVED_LOGIN_KEY] = True
        session.save()

    @override_settings(GITHUB_CLIENT_ID="client-id", GITHUB_CLIENT_SECRET="client-secret")
    def test_login_page_prompts_for_github(self):
        response = self.client.get(reverse("login"))
        self.assertContains(response, "Continue with GitHub")
        self.assertContains(response, "GitHub OAuth")

    def test_logout_redirects_home(self):
        user = get_user_model().objects.create_user(username="logout-user", password="secret")
        profile = get_or_create_profile_for_user(user)
        profile.approval_state = ApprovalState.APPROVED
        profile.save(update_fields=["approval_state"])
        self.client.force_login(user)
        session = self.client.session
        session[SESSION_APPROVED_LOGIN_KEY] = True
        session.save()

        response = self.client.get(reverse("logout"))

        self.assertRedirects(response, reverse("home"), fetch_redirect_response=False)

    def test_navbar_shows_display_name_not_github_username(self):
        user = get_user_model().objects.create_user(
            username="github-1778366",
            first_name="Octo Cat",
            password="secret",
        )
        profile = get_or_create_profile_for_user(user)
        profile.approval_state = ApprovalState.APPROVED
        profile.github_login = "octocat"
        profile.save(update_fields=["approval_state", "github_login"])
        self.client.force_login(user)
        session = self.client.session
        session[SESSION_APPROVED_LOGIN_KEY] = True
        session.save()

        response = self.client.get(reverse("home"))

        self.assertContains(response, "Signed in as Octo Cat")

    def test_github_callback_creates_pending_profile_and_redirects_to_status(self):
        session = self.client.session
        session[SESSION_OAUTH_STATE_KEY] = "state-123"
        session[SESSION_OAUTH_NEXT_KEY] = "/"
        session.save()

        with (
            patch("portal.views.exchange_code_for_token", return_value="token"),
            patch(
                "portal.views.fetch_github_account",
                return_value={
                    "id": "123456",
                    "login": "octocat",
                    "name": "Octo Cat",
                    "avatar_url": "https://example.org/avatar.png",
                    "email": "octocat@example.org",
                    "html_url": "https://github.com/octocat",
                },
            ),
            patch("portal.views.notify_admins_new_pending_user") as notify_mock,
        ):
            response = self.client.get(
                reverse("github-callback"),
                {"state": "state-123", "code": "code-abc"},
            )

        self.assertRedirects(
            response,
            reverse("auth-status"),
            fetch_redirect_response=False,
        )
        profile = UserProfile.objects.get(github_id="123456")
        self.assertEqual(profile.approval_state, ApprovalState.PENDING)
        self.assertEqual(profile.github_login, "octocat")
        notify_mock.assert_called_once()
        self.assertFalse(self.client.session[SESSION_APPROVED_LOGIN_KEY])

        home_response = self.client.get(reverse("home"))
        self.assertRedirects(
            home_response,
            reverse("auth-status"),
            fetch_redirect_response=False,
        )

        status_response = self.client.get(reverse("auth-status"))
        self.assertNotContains(status_response, "Sign in again with GitHub")
        self.assertNotContains(status_response, "Relogin with GitHub")

    def test_github_callback_ignores_admin_notification_email_failures(self):
        session = self.client.session
        session[SESSION_OAUTH_STATE_KEY] = "state-123"
        session[SESSION_OAUTH_NEXT_KEY] = "/"
        session.save()

        with (
            patch("portal.views.exchange_code_for_token", return_value="token"),
            patch(
                "portal.views.fetch_github_account",
                return_value={
                    "id": "123456",
                    "login": "octocat",
                    "name": "Octo Cat",
                    "avatar_url": "https://example.org/avatar.png",
                    "email": "octocat@example.org",
                    "html_url": "https://github.com/octocat",
                },
            ),
            patch("portal.notifications.send_mail", side_effect=OSError("smtp unavailable")),
        ):
            response = self.client.get(
                reverse("github-callback"),
                {"state": "state-123", "code": "code-abc"},
            )

        self.assertRedirects(
            response,
            reverse("auth-status"),
            fetch_redirect_response=False,
        )
        profile = UserProfile.objects.get(github_id="123456")
        self.assertEqual(profile.approval_state, ApprovalState.PENDING)
        self.assertFalse(self.client.session[SESSION_APPROVED_LOGIN_KEY])

    def test_github_callback_turns_github_http_errors_into_login_redirect(self):
        session = self.client.session
        session[SESSION_OAUTH_STATE_KEY] = "state-123"
        session[SESSION_OAUTH_NEXT_KEY] = "/"
        session.save()

        http_error = urllib.error.HTTPError(
            url="https://github.com/login/oauth/access_token",
            code=400,
            msg="Bad Request",
            hdrs=None,
            fp=None,
        )
        with patch("portal.views.exchange_code_for_token", side_effect=http_error):
            response = self.client.get(
                reverse("github-callback"),
                {"state": "state-123", "code": "code-abc"},
            )

        self.assertRedirects(
            response,
            reverse("login"),
            fetch_redirect_response=False,
        )

    def test_github_callback_logs_unexpected_errors_and_redirects_to_login(self):
        session = self.client.session
        session[SESSION_OAUTH_STATE_KEY] = "state-123"
        session[SESSION_OAUTH_NEXT_KEY] = "/"
        session.save()

        with (
            patch("portal.views.exchange_code_for_token", return_value="token"),
            patch(
                "portal.views.fetch_github_account",
                return_value={
                    "id": "123456",
                    "login": "octocat",
                    "name": "Octo Cat",
                    "avatar_url": "https://example.org/avatar.png",
                    "email": "octocat@example.org",
                    "html_url": "https://github.com/octocat",
                },
            ),
            patch("portal.views.get_or_create_profile_from_github", side_effect=RuntimeError("boom")),
        ):
            with self.assertLogs("portal.views", level="ERROR") as logs:
                response = self.client.get(
                    reverse("github-callback"),
                    {"state": "state-123", "code": "code-abc"},
                )

        self.assertRedirects(
            response,
            reverse("login"),
            fetch_redirect_response=False,
        )
        self.assertTrue(any("GitHub callback failed after successful authorization" in line for line in logs.output))

    @override_settings(
        GITHUB_CLIENT_ID="client",
        GITHUB_CLIENT_SECRET="secret",
        PUBLIC_BASE_URL="https://hep-data-llm.eastus.cloudapp.azure.com",
    )
    def test_github_login_redirect_uses_https_callback_when_public_base_url_is_set(self):
        response = self.client.get(reverse("github-login"))

        self.assertIn("redirect_uri=https%3A%2F%2F", response["Location"])
        self.assertIn("%2Faccounts%2Fgithub%2Fcallback%2F", response["Location"])

    def test_admin_can_approve_user_and_user_refreshes_into_app(self):
        target_user = get_user_model().objects.create_user(
            username="pending-user",
            email="pending@example.org",
            password="secret",
        )
        self._force_pending_login(target_user)

        admin_client = Client()
        admin_client.force_login(self.admin_user)
        admin_session = admin_client.session
        admin_session[SESSION_APPROVED_LOGIN_KEY] = True
        admin_session.save()

        with patch("portal.views.notify_user_account_decision") as notify_mock:
            response = admin_client.post(
                reverse(
                    "admin-user-decision",
                    kwargs={"profile_id": target_user.profile.pk, "decision": "approve"},
                )
            )
        self.assertRedirects(
            response,
            reverse("admin-users"),
            fetch_redirect_response=False,
        )
        target_user.profile.refresh_from_db()
        self.assertEqual(target_user.profile.approval_state, ApprovalState.APPROVED)
        notify_mock.assert_called_once()

        self.assertFalse(self.client.session[SESSION_APPROVED_LOGIN_KEY])

        refresh_response = self.client.get(reverse("auth-status"))
        self.assertRedirects(
            refresh_response,
            reverse("home"),
            fetch_redirect_response=False,
        )
        self.assertTrue(self.client.session[SESSION_APPROVED_LOGIN_KEY])

        allowed_response = self.client.get(reverse("home"))
        self.assertEqual(allowed_response.status_code, 200)
        self.assertContains(allowed_response, "Ask for a plot in plain language")

    def test_rejected_user_refresh_stays_blocked(self):
        target_user = get_user_model().objects.create_user(
            username="rejected-user",
            email="rejected@example.org",
            password="secret",
        )
        profile = get_or_create_profile_for_user(target_user)
        profile.approval_state = ApprovalState.REJECTED
        profile.save(update_fields=["approval_state"])
        self.client.force_login(target_user)
        session = self.client.session
        session[SESSION_APPROVED_LOGIN_KEY] = False
        session.save()

        response = self.client.get(reverse("auth-status"))

        self.assertContains(response, "Your account was rejected")
        self.assertFalse(self.client.session[SESSION_APPROVED_LOGIN_KEY])
        blocked_response = self.client.get(reverse("home"))
        self.assertRedirects(
            blocked_response,
            reverse("auth-status"),
            fetch_redirect_response=False,
        )
