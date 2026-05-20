from __future__ import annotations

import mimetypes
from pathlib import Path
from random import sample

from django.contrib import messages
from django.contrib.auth import logout as auth_logout
from django.contrib.auth.decorators import login_required
from django.core.exceptions import PermissionDenied
from django.http import FileResponse, Http404, HttpResponseRedirect
from django.shortcuts import get_object_or_404, render
from django.urls import reverse
from django.utils import timezone

from portal.auth import (
    SESSION_APPROVED_LOGIN_KEY,
    SESSION_OAUTH_NEXT_KEY,
    SESSION_OAUTH_STATE_KEY,
    exchange_code_for_token,
    fetch_github_account,
    github_oauth_enabled,
    login_user,
    profile_has_admin_access,
    profile_has_app_access,
    safe_next_url,
    start_github_login,
)
from portal.backend import available_profile_choices, load_example_questions
from portal.models import (
    ApprovalState,
    Job,
    JobArtifact,
    JobStatus,
    UserProfile,
    get_or_create_profile_for_user,
)
from portal.notifications import (
    notify_admins_new_pending_user,
    notify_user_account_decision,
)
from portal.services import QueueFullError, create_job

JOB_BADGE_CLASSES = {
    JobStatus.QUEUED: "text-bg-secondary",
    JobStatus.RUNNING: "text-bg-primary",
    JobStatus.COMPLETED: "text-bg-success",
    JobStatus.FAILED: "text-bg-danger",
    JobStatus.CANCELLED: "text-bg-warning",
}


def featured_example_questions():
    example_questions = load_example_questions()
    if len(example_questions) <= 3:
        return example_questions
    return sample(example_questions, 3)


def _job_badge_class(status: str) -> str:
    return JOB_BADGE_CLASSES.get(status, "text-bg-secondary")


def _job_accessible_to_user(request, job: Job) -> bool:
    return request.user.is_staff or job.owner_id == request.user.id


def _job_or_404(request, submission_id):
    job = get_object_or_404(Job, submission_id=submission_id)
    if not _job_accessible_to_user(request, job):
        raise Http404
    return job


def _job_history_rows(request):
    if not request.user.is_authenticated:
        return []

    jobs = (
        Job.objects.filter(owner=request.user)
        .select_related("owner")
        .order_by("-submitted_at", "-pk")[:10]
    )
    return [
        {
            "job": job,
            "submitted_at": timezone.localtime(job.submitted_at),
            "status_label": job.get_status_display(),
            "badge_class": _job_badge_class(job.status),
            "queue_position": job.queue_position,
            "view_url": reverse("job-detail", kwargs={"submission_id": job.submission_id}),
            "clone_url": reverse("job-clone", kwargs={"submission_id": job.submission_id}),
        }
        for job in jobs
    ]


def _admin_profile_or_403(request):
    profile = get_or_create_profile_for_user(request.user)
    if not profile_has_admin_access(
        profile,
        session_approved=bool(request.session.get(SESSION_APPROVED_LOGIN_KEY)),
        user_is_staff=request.user.is_staff,
    ):
        raise PermissionDenied
    return profile


def login(request):
    if request.user.is_authenticated:
        return HttpResponseRedirect(reverse("home"))

    next_url = safe_next_url(request, request.GET.get("next"))
    return render(
        request,
        "registration/login.html",
        {
            "page_title": "Log in",
            "github_oauth_enabled": github_oauth_enabled(),
            "github_login_url": reverse("github-login"),
            "next_url": next_url,
        },
    )


def logout(request):
    auth_logout(request)
    return HttpResponseRedirect(reverse("home"))


def github_login(request):
    next_url = safe_next_url(
        request, request.GET.get("next") or request.session.get(SESSION_OAUTH_NEXT_KEY)
    )
    try:
        redirect_url = start_github_login(request, next_url)
    except PermissionDenied as exc:
        messages.error(request, str(exc))
        return HttpResponseRedirect(reverse("login"))
    return HttpResponseRedirect(redirect_url)


def github_callback(request):
    error = request.GET.get("error")
    if error:
        messages.error(request, f"GitHub login was cancelled or failed: {error}.")
        return HttpResponseRedirect(reverse("login"))

    state = request.GET.get("state", "")
    expected_state = request.session.get(SESSION_OAUTH_STATE_KEY)
    if not state or state != expected_state:
        messages.error(request, "GitHub login could not be verified. Please try again.")
        return HttpResponseRedirect(reverse("login"))

    code = request.GET.get("code", "")
    if not code:
        messages.error(request, "GitHub login did not return an authorization code.")
        return HttpResponseRedirect(reverse("login"))

    redirect_uri = request.build_absolute_uri(reverse("github-callback"))
    try:
        access_token = exchange_code_for_token(code=code, redirect_uri=redirect_uri)
        account = fetch_github_account(access_token)
    except (OSError, PermissionDenied) as exc:
        messages.error(request, f"GitHub login failed: {exc}")
        return HttpResponseRedirect(reverse("login"))

    profile = get_or_create_profile_from_github(account)
    if profile.approval_state == ApprovalState.PENDING and profile.pending_notified_at is None:
        notify_admins_new_pending_user(profile)
        profile.pending_notified_at = timezone.now()
        profile.save(update_fields=["pending_notified_at"])

    approved = profile.approval_state == ApprovalState.APPROVED
    next_url = safe_next_url(request, request.session.get(SESSION_OAUTH_NEXT_KEY))
    login_user(request, profile, approved=approved, next_url=next_url)

    request.session.pop(SESSION_OAUTH_STATE_KEY, None)
    request.session.pop(SESSION_OAUTH_NEXT_KEY, None)

    if approved:
        messages.success(request, "Signed in with GitHub.")
        return HttpResponseRedirect(next_url or reverse("home"))

    messages.info(request, "Your account is waiting for approval.")
    return HttpResponseRedirect(reverse("auth-status"))


@login_required
def auth_status(request):
    profile = get_or_create_profile_for_user(request.user)
    profile.refresh_from_db()
    session_approved = bool(request.session.get(SESSION_APPROVED_LOGIN_KEY))
    if profile.approval_state == ApprovalState.APPROVED:
        if not session_approved:
            request.session[SESSION_APPROVED_LOGIN_KEY] = True
            request.session.modified = True
            return HttpResponseRedirect(reverse("home"))
        session_approved = True
    elif session_approved:
        request.session[SESSION_APPROVED_LOGIN_KEY] = False
        request.session.modified = True
        session_approved = False
    return render(
        request,
        "portal/auth_status.html",
        {
            "page_title": "Account status",
            "profile": profile,
            "session_approved": session_approved,
            "app_access_granted": profile_has_app_access(
                profile, session_approved=session_approved
            ),
            "github_login_url": reverse("github-login"),
            "logout_url": reverse("logout"),
        },
    )


def get_or_create_profile_from_github(account: dict[str, str]) -> UserProfile:
    from portal.auth import sync_github_user

    return sync_github_user(account)


@login_required
def admin_users(request):
    _admin_profile_or_403(request)
    profiles = UserProfile.objects.select_related("user").order_by(
        "approval_state", "role", "user__username", "pk"
    )
    return render(
        request,
        "portal/admin_users.html",
        {
            "page_title": "User approvals",
            "profiles": profiles,
        },
    )


@login_required
def admin_user_decision(request, profile_id: int, decision: str):
    _admin_profile_or_403(request)
    if request.method != "POST":
        return HttpResponseRedirect(reverse("admin-users"))

    profile = get_object_or_404(UserProfile, pk=profile_id)
    if decision not in {"approve", "reject"}:
        raise PermissionDenied

    now = timezone.now()
    if decision == "approve":
        profile.approval_state = ApprovalState.APPROVED
        profile.approved_at = now
        profile.rejected_at = None
    else:
        profile.approval_state = ApprovalState.REJECTED
        profile.rejected_at = now
        profile.approved_at = None
    profile.decided_at = now
    profile.save(
        update_fields=[
            "approval_state",
            "approved_at",
            "rejected_at",
            "decided_at",
        ]
    )
    notify_user_account_decision(profile, decision=ApprovalState(profile.approval_state))

    action_word = "approved" if decision == "approve" else "rejected"
    messages.success(request, f"{profile.user.get_username()} was {action_word}.")
    return HttpResponseRedirect(reverse("admin-users"))


def home(request):
    return render(
        request,
        "portal/home.html",
        {
            "page_title": "HEP Data LLM",
            "example_questions": featured_example_questions(),
            "profile_choices": available_profile_choices(),
            "history_rows": _job_history_rows(request),
            "submit_url": reverse("submit-job"),
        },
    )


@login_required
def submit_job(request):
    if request.method != "POST":
        return HttpResponseRedirect(reverse("home"))

    prompt = request.POST.get("prompt", "").strip()
    dataset = request.POST.get("dataset", "").strip() or None
    backend_profile = request.POST.get("profile", "").strip()

    if not prompt:
        messages.error(request, "Please enter a prompt before submitting.")
        return HttpResponseRedirect(reverse("home"))

    try:
        job = create_job(
            owner=request.user,
            prompt=prompt,
            dataset=dataset,
            backend_profile=backend_profile,
        )
    except QueueFullError as exc:
        messages.error(request, str(exc))
        return HttpResponseRedirect(reverse("home"))
    except ValueError as exc:
        messages.error(request, str(exc))
        return HttpResponseRedirect(reverse("home"))

    messages.success(request, "Your request has been queued.")
    return HttpResponseRedirect(reverse("job-detail", kwargs={"submission_id": job.submission_id}))


@login_required
def job_detail(request, submission_id):
    job = _job_or_404(request, submission_id)
    artifacts = list(job.artifacts.all().order_by("created_at", "pk"))
    image_artifacts = [
        artifact
        for artifact in artifacts
        if mimetypes.guess_type(artifact.path)[0] in {"image/png", "image/jpeg", "image/gif"}
        or artifact.path.lower().endswith(".png")
    ]
    report_artifact = next((artifact for artifact in artifacts if artifact.is_canonical), None)

    return render(
        request,
        "portal/job_detail.html",
        {
            "job": job,
            "report_artifact": report_artifact,
            "artifacts": artifacts,
            "image_artifacts": image_artifacts,
            "queue_position": job.queue_position,
            "badge_class": _job_badge_class(job.status),
            "submitted_at": timezone.localtime(job.submitted_at),
            "started_at": timezone.localtime(job.started_at) if job.started_at else None,
            "completed_at": timezone.localtime(job.completed_at) if job.completed_at else None,
        },
    )


@login_required
def clone_job(request, submission_id):
    source_job = _job_or_404(request, submission_id)
    if request.method == "POST":
        prompt = request.POST.get("prompt", "").strip()
        dataset = request.POST.get("dataset", "").strip() or None
        backend_profile = request.POST.get("profile", source_job.backend_profile).strip()

        if not prompt:
            messages.error(request, "Please enter a prompt before resubmitting.")
        else:
            try:
                cloned_job = create_job(
                    owner=request.user,
                    prompt=prompt,
                    dataset=dataset,
                    backend_profile=backend_profile,
                )
            except QueueFullError as exc:
                messages.error(request, str(exc))
            except ValueError as exc:
                messages.error(request, str(exc))
            else:
                messages.success(request, "Your cloned request has been queued.")
                return HttpResponseRedirect(
                    reverse("job-detail", kwargs={"submission_id": cloned_job.submission_id})
                )

    return render(
        request,
        "portal/job_clone.html",
        {
            "source_job": source_job,
            "profile_choices": available_profile_choices(),
            "prompt_value": source_job.original_prompt,
            "dataset_value": source_job.resolved_dataset,
            "selected_profile": source_job.backend_profile,
        },
    )


@login_required
def job_artifact_download(request, submission_id, artifact_id):
    job = _job_or_404(request, submission_id)
    artifact = get_object_or_404(JobArtifact, pk=artifact_id, job=job)
    artifact_path = Path(artifact.path)
    if not artifact_path.exists():
        raise Http404

    response = FileResponse(artifact_path.open("rb"), as_attachment=True)
    response["Content-Disposition"] = f'attachment; filename="{artifact_path.name}"'
    content_type, _ = mimetypes.guess_type(artifact_path.name)
    if content_type:
        response["Content-Type"] = content_type
    return response


@login_required
def job_artifact_inline(request, submission_id, artifact_id):
    job = _job_or_404(request, submission_id)
    artifact = get_object_or_404(JobArtifact, pk=artifact_id, job=job)
    artifact_path = Path(artifact.path)
    if not artifact_path.exists():
        raise Http404

    response = FileResponse(artifact_path.open("rb"), as_attachment=False)
    response["Content-Disposition"] = f'inline; filename="{artifact_path.name}"'
    content_type, _ = mimetypes.guess_type(artifact_path.name)
    if content_type:
        response["Content-Type"] = content_type
    return response
