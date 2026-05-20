from __future__ import annotations

from django.conf import settings
from django.core.mail import send_mail

from portal.models import ApprovalState


def _admin_recipients() -> list[str]:
    recipients = set()
    for email, _name in getattr(settings, "ADMINS", ()):
        if email:
            recipients.add(email)
    return sorted(recipients)


def notify_admins_new_pending_user(profile) -> None:
    recipients = _admin_recipients()
    if not recipients:
        return

    subject = f"New pending user: {profile.user.get_username()}"
    message = "\n".join(
        [
            "A new user signed in with GitHub and is waiting for approval.",
            "",
            f"GitHub login: {profile.github_login or profile.user.get_username()}",
            f"GitHub id: {profile.github_id or 'unknown'}",
            f"Email: {profile.github_email or profile.user.email or 'not provided'}",
            f"Name: {profile.user.get_full_name() or profile.user.get_username()}",
            "",
            "Review them at /admin/users/ while signed in as an admin.",
        ]
    )
    send_mail(subject, message, settings.DEFAULT_FROM_EMAIL, recipients)


def notify_user_account_decision(profile, *, decision: ApprovalState) -> None:
    recipient = profile.user.email or profile.github_email
    if not recipient:
        return

    if decision == ApprovalState.APPROVED:
        subject = "Your HEP Data LLM account was approved"
        message = "\n".join(
            [
                "Your account was approved and you can now sign in again.",
                "",
                "Please log out and sign back in with GitHub to refresh your session.",
            ]
        )
    else:
        subject = "Your HEP Data LLM account was rejected"
        message = "\n".join(
            [
                "Your account request was rejected by an administrator.",
                "",
                "If you think this was a mistake, please contact an admin.",
            ]
        )

    send_mail(subject, message, settings.DEFAULT_FROM_EMAIL, [recipient])
