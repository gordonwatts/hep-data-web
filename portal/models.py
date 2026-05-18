from __future__ import annotations

import uuid

from django.conf import settings
from django.db import models
from django.utils import timezone

from portal.backend import available_profile_choices


class JobStatus(models.TextChoices):
    QUEUED = "queued", "Queued"
    RUNNING = "running", "Running"
    COMPLETED = "completed", "Completed"
    FAILED = "failed", "Failed"
    CANCELLED = "cancelled", "Cancelled"


class Job(models.Model):
    submission_id = models.UUIDField(default=uuid.uuid4, editable=False, unique=True)
    owner = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.CASCADE,
        related_name="jobs",
    )
    original_prompt = models.TextField()
    resolved_dataset = models.TextField(blank=True)
    backend_profile = models.CharField(
        max_length=32,
        choices=[(choice.value, choice.label) for choice in available_profile_choices()],
    )
    status = models.CharField(
        max_length=16,
        choices=JobStatus.choices,
        default=JobStatus.QUEUED,
        db_index=True,
    )
    queue_position = models.PositiveIntegerField(null=True, blank=True)
    queue_depth_at_submission = models.PositiveIntegerField(default=0)
    submitted_at = models.DateTimeField(default=timezone.now, db_index=True)
    started_at = models.DateTimeField(null=True, blank=True)
    completed_at = models.DateTimeField(null=True, blank=True)
    runtime = models.DurationField(null=True, blank=True)
    failure_message = models.TextField(blank=True)
    generated_code = models.TextField(blank=True)
    result_metadata = models.JSONField(default=dict, blank=True)

    class Meta:
        ordering = ["-submitted_at", "-pk"]

    def __str__(self) -> str:
        return f"Job {self.pk or self.submission_id} ({self.status})"


class JobArtifact(models.Model):
    job = models.ForeignKey(Job, on_delete=models.CASCADE, related_name="artifacts")
    artifact_kind = models.CharField(max_length=64)
    path = models.TextField()
    is_canonical = models.BooleanField(default=False)
    created_at = models.DateTimeField(default=timezone.now)

    class Meta:
        ordering = ["created_at", "pk"]

    def __str__(self) -> str:
        return f"{self.artifact_kind} for job {self.job_id}"
