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


class ApprovalState(models.TextChoices):
    PENDING = "pending", "Pending"
    APPROVED = "approved", "Approved"
    REJECTED = "rejected", "Rejected"


class UserRole(models.TextChoices):
    USER = "user", "User"
    ADMIN = "admin", "Admin"


class UserProfile(models.Model):
    user = models.OneToOneField(
        settings.AUTH_USER_MODEL, on_delete=models.CASCADE, related_name="profile"
    )
    github_id = models.CharField(max_length=32, unique=True, null=True, blank=True)
    github_login = models.CharField(max_length=255, blank=True)
    github_avatar_url = models.URLField(blank=True)
    github_email = models.EmailField(blank=True)
    role = models.CharField(
        max_length=16, choices=UserRole.choices, default=UserRole.USER, db_index=True
    )
    approval_state = models.CharField(
        max_length=16,
        choices=ApprovalState.choices,
        default=ApprovalState.PENDING,
        db_index=True,
    )
    pending_notified_at = models.DateTimeField(null=True, blank=True)
    decided_at = models.DateTimeField(null=True, blank=True)
    approved_at = models.DateTimeField(null=True, blank=True)
    rejected_at = models.DateTimeField(null=True, blank=True)
    created_at = models.DateTimeField(default=timezone.now)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        ordering = ["-updated_at", "-pk"]

    def __str__(self) -> str:
        return f"Profile for {self.user}"

    @property
    def is_approved(self) -> bool:
        return self.approval_state == ApprovalState.APPROVED

    @property
    def is_pending(self) -> bool:
        return self.approval_state == ApprovalState.PENDING

    @property
    def is_rejected(self) -> bool:
        return self.approval_state == ApprovalState.REJECTED


def get_or_create_profile_for_user(user):
    profile_defaults = {
        "role": UserRole.ADMIN if user.is_staff or user.is_superuser else UserRole.USER,
        "approval_state": ApprovalState.APPROVED
        if user.is_staff or user.is_superuser
        else ApprovalState.PENDING,
    }
    profile, _ = UserProfile.objects.get_or_create(user=user, defaults=profile_defaults)
    return profile
