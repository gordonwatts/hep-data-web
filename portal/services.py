from __future__ import annotations

import os
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from django.conf import settings
from django.db import transaction
from django.utils import timezone

from portal.backend import (
    backend_config_name_for_profile,
    default_dataset,
    render_job_prompt,
    validate_backend_profile,
)
from portal.models import Job, JobStatus


class QueueFullError(RuntimeError):
    pass


@dataclass(frozen=True)
class JobExecutionResult:
    output_path: Path
    generated_code: str
    stdout: str
    stderr: str
    exit_code: int
    artifact_paths: tuple[Path, ...]
    metadata: dict[str, Any]


def active_job_count() -> int:
    return Job.objects.filter(status__in=[JobStatus.QUEUED, JobStatus.RUNNING]).count()


def queue_position_for(job: Job) -> int | None:
    if job.status not in {JobStatus.QUEUED, JobStatus.RUNNING}:
        return None

    queued_jobs = (
        Job.objects.filter(status__in=[JobStatus.QUEUED, JobStatus.RUNNING])
        .order_by("submitted_at", "pk")
        .values_list("pk", flat=True)
    )
    for index, pk in enumerate(queued_jobs, start=1):
        if pk == job.pk:
            return index
    return None


def refresh_queue_positions() -> None:
    queued_jobs = list(
        Job.objects.filter(status__in=[JobStatus.QUEUED, JobStatus.RUNNING]).order_by(
            "submitted_at", "pk"
        )
    )
    for index, job in enumerate(queued_jobs, start=1):
        if job.queue_position != index:
            Job.objects.filter(pk=job.pk).update(queue_position=index)


def artifact_directory_for_job(job: Job) -> Path:
    return Path(settings.ARTIFACT_ROOT) / f"job-{job.submission_id}"


def artifact_path_for_job(job: Job, filename: str) -> Path:
    return artifact_directory_for_job(job) / Path(filename).name


def _backend_cache_root() -> Path:
    cache_root = Path(settings.BASE_DIR) / ".cache"
    cache_root.mkdir(parents=True, exist_ok=True)
    return cache_root


def _backend_command_for_job(job: Job, output_path: Path) -> list[str]:
    prompt = render_job_prompt(job.original_prompt, job.resolved_dataset)
    command = [
        sys.executable,
        "-m",
        "hep_data_llm.cli",
        "plot",
        prompt,
        str(output_path),
        "--profile",
        backend_config_name_for_profile(job.backend_profile),
    ]
    docker_image = getattr(settings, "HEP_DATA_LLM_DOCKER_IMAGE", "")
    if docker_image:
        command.extend(["--docker-image", docker_image])
    return command


def _extract_generated_code(markdown_text: str) -> str:
    python_blocks = re.findall(r"```python(.*?)```", markdown_text, re.DOTALL | re.IGNORECASE)
    if python_blocks:
        return python_blocks[-1].strip()
    generic_blocks = re.findall(r"```(.*?)```", markdown_text, re.DOTALL)
    if generic_blocks:
        return generic_blocks[-1].strip()
    return ""


def run_backend_job(job: Job) -> JobExecutionResult:
    output_dir = artifact_directory_for_job(job)
    output_dir.mkdir(parents=True, exist_ok=True)
    output_path = output_dir / "result.md"

    env = os.environ.copy()
    home_dir = str(getattr(settings, "HEP_DATA_LLM_HOME_DIR", settings.BASE_DIR))
    env["HOME"] = home_dir
    env["USERPROFILE"] = home_dir
    env["XDG_CACHE_HOME"] = str(_backend_cache_root())

    proc = subprocess.run(
        _backend_command_for_job(job, output_path),
        cwd=str(settings.BASE_DIR),
        env=env,
        capture_output=True,
        text=True,
        encoding="utf-8",
    )

    markdown_text = ""
    if output_path.exists():
        markdown_text = output_path.read_text(encoding="utf-8")

    image_paths = tuple(sorted(output_dir.glob("img/*.png")))
    metadata = {
        "command": _backend_command_for_job(job, output_path),
        "output_path": str(output_path),
        "image_paths": [str(path) for path in image_paths],
        "returncode": proc.returncode,
    }
    return JobExecutionResult(
        output_path=output_path,
        generated_code=_extract_generated_code(markdown_text),
        stdout=proc.stdout,
        stderr=proc.stderr,
        exit_code=proc.returncode,
        artifact_paths=(output_path, *image_paths),
        metadata=metadata,
    )


@transaction.atomic
def start_queued_job(job: Job) -> Job:
    locked_job = Job.objects.select_for_update().get(pk=job.pk)
    if locked_job.status != JobStatus.QUEUED:
        raise ValueError("Job must be queued before it can start")

    locked_job.status = JobStatus.RUNNING
    locked_job.started_at = timezone.now()
    locked_job.queue_position = 1
    locked_job.save(update_fields=["status", "started_at", "queue_position"])
    refresh_queue_positions()
    return locked_job


def record_job_artifacts(job: Job, result: JobExecutionResult) -> None:
    from portal.models import JobArtifact

    JobArtifact.objects.filter(job=job).delete()
    for path in result.artifact_paths:
        JobArtifact.objects.create(
            job=job,
            artifact_kind="report" if path.suffix.lower() in {".md", ".txt"} else "plot",
            path=str(path),
            is_canonical=path == result.output_path,
        )


@transaction.atomic
def claim_next_queued_job() -> Job | None:
    job = (
        Job.objects.select_for_update(skip_locked=True)
        .filter(status=JobStatus.QUEUED)
        .order_by("submitted_at", "pk")
        .first()
    )
    if job is None:
        return None

    return start_queued_job(job)


def mark_job_completed(job: Job, result: JobExecutionResult) -> Job:
    job.status = JobStatus.COMPLETED if result.exit_code == 0 else JobStatus.FAILED
    job.completed_at = timezone.now()
    if job.started_at:
        job.runtime = job.completed_at - job.started_at
    job.generated_code = result.generated_code
    job.failure_message = "" if result.exit_code == 0 else result.stderr.strip()
    job.result_metadata = result.metadata
    job.queue_position = None
    job.save(
        update_fields=[
            "status",
            "completed_at",
            "runtime",
            "generated_code",
            "failure_message",
            "result_metadata",
            "queue_position",
        ]
    )
    record_job_artifacts(job, result)
    refresh_queue_positions()
    return job


def mark_job_failed(job: Job, message: str) -> Job:
    job.status = JobStatus.FAILED
    job.completed_at = timezone.now()
    if job.started_at:
        job.runtime = job.completed_at - job.started_at
    job.failure_message = message
    job.queue_position = None
    job.save(
        update_fields=[
            "status",
            "completed_at",
            "runtime",
            "failure_message",
            "queue_position",
        ]
    )
    refresh_queue_positions()
    return job


def process_job(job: Job, *, executor=run_backend_job) -> Job:
    if job.status != JobStatus.RUNNING:
        raise ValueError("Job must be running before processing")

    try:
        result = executor(job)
    except Exception as exc:  # pragma: no cover - exercised through tests with fakes
        return mark_job_failed(job, str(exc))

    return mark_job_completed(job, result)


def claim_and_process_next_job(*, executor=run_backend_job) -> Job | None:
    job = claim_next_queued_job()
    if job is None:
        return None
    return process_job(job, executor=executor)


@transaction.atomic
def create_job(*, owner, prompt: str, dataset: str | None, backend_profile: str) -> Job:
    current_queue_depth = active_job_count()
    if current_queue_depth >= settings.JOB_QUEUE_LIMIT:
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
        queue_depth_at_submission=current_queue_depth,
        queue_position=current_queue_depth + 1,
    )
    refresh_queue_positions()
    return job
