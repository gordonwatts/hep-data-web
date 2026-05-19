from __future__ import annotations

import mimetypes
from pathlib import Path
from random import sample

from django.contrib import messages
from django.contrib.auth.decorators import login_required
from django.http import FileResponse, Http404, HttpResponseRedirect
from django.shortcuts import get_object_or_404, render
from django.urls import reverse
from django.utils import timezone

from portal.backend import available_profile_choices, load_example_questions
from portal.models import Job, JobArtifact, JobStatus
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
