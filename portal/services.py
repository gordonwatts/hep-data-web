from __future__ import annotations

from pathlib import Path

from django.conf import settings
from django.db import transaction

from portal.backend import default_dataset, validate_backend_profile
from portal.models import Job, JobStatus


class QueueFullError(RuntimeError):
    pass


def active_job_count() -> int:
    return Job.objects.filter(status__in=[JobStatus.QUEUED, JobStatus.RUNNING]).count()


def queue_position_for(job: Job) -> int | None:
    if job.status not in {JobStatus.QUEUED, JobStatus.RUNNING}:
        return None

    earlier_jobs = Job.objects.filter(
        status__in=[JobStatus.QUEUED, JobStatus.RUNNING],
        submitted_at__lt=job.submitted_at,
    ).count()
    return earlier_jobs + 1


def artifact_directory_for_job(job: Job) -> Path:
    return Path(settings.ARTIFACT_ROOT) / f"job-{job.submission_id}"


def artifact_path_for_job(job: Job, filename: str) -> Path:
    return artifact_directory_for_job(job) / Path(filename).name


@transaction.atomic
def create_job(*, owner, prompt: str, dataset: str | None, backend_profile: str) -> Job:
    if active_job_count() >= settings.JOB_QUEUE_LIMIT:
        raise QueueFullError("System appears busy or jammed, please try again later")

    resolved_dataset = dataset or default_dataset()
    if not resolved_dataset:
        raise RuntimeError("No default dataset is configured")

    job = Job.objects.create(
        owner=owner,
        original_prompt=prompt,
        resolved_dataset=resolved_dataset,
        backend_profile=validate_backend_profile(backend_profile),
        status=JobStatus.QUEUED,
        queue_depth_at_submission=active_job_count(),
        queue_position=active_job_count() + 1,
    )
    return job
