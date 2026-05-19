import os
import subprocess
from datetime import timedelta
from unittest.mock import patch

from django.contrib.auth import get_user_model
from django.test import TestCase

from portal import services
from portal.models import Job, JobArtifact, JobStatus


class JobServiceTests(TestCase):
    def setUp(self):
        self.user = get_user_model().objects.create_user(
            username="analyst",
            email="analyst@example.org",
            password="secret",
        )

    def test_create_job_injects_default_dataset(self):
        services.default_dataset = lambda: "default-dataset"  # type: ignore[assignment]

        job = services.create_job(
            owner=self.user,
            prompt="plot the leading jet",
            dataset=None,
            backend_profile="rdf",
        )

        self.assertEqual(job.resolved_dataset, "default-dataset")
        self.assertEqual(job.backend_profile, "rdf")
        self.assertEqual(job.status, JobStatus.QUEUED)
        self.assertEqual(job.queue_position, 1)

    def test_create_job_rejects_when_queue_is_full(self):
        services.default_dataset = lambda: "default-dataset"  # type: ignore[assignment]
        for index in range(20):
            Job.objects.create(
                owner=self.user,
                original_prompt=f"prompt {index}",
                resolved_dataset="default-dataset",
                backend_profile="rdf",
                status=JobStatus.QUEUED,
            )

        with self.assertRaisesMessage(
            services.QueueFullError,
            "System appears busy or jammed, please try again later",
        ):
            services.create_job(
                owner=self.user,
                prompt="plot the missing transverse energy",
                dataset=None,
                backend_profile="rdf",
            )

    def test_queue_position_uses_submission_order(self):
        services.default_dataset = lambda: "default-dataset"  # type: ignore[assignment]
        first = Job.objects.create(
            owner=self.user,
            original_prompt="first",
            resolved_dataset="default-dataset",
            backend_profile="rdf",
            status=JobStatus.QUEUED,
        )
        second = Job.objects.create(
            owner=self.user,
            original_prompt="second",
            resolved_dataset="default-dataset",
            backend_profile="rdf",
            status=JobStatus.QUEUED,
        )
        Job.objects.filter(pk=second.pk).update(
            submitted_at=first.submitted_at + timedelta(seconds=1)
        )
        second.refresh_from_db()

        assert services.queue_position_for(first) == 1
        assert services.queue_position_for(second) == 2


class ArtifactConventionTests(TestCase):
    def test_artifact_paths_live_under_persistent_root(self):
        user = get_user_model().objects.create_user(username="analyst2")
        job = Job.objects.create(
            owner=user,
            original_prompt="prompt",
            resolved_dataset="dataset",
            backend_profile="rdf",
            status=JobStatus.RUNNING,
        )
        path = services.artifact_path_for_job(job, "../result.png")
        assert str(path).startswith(str(services.artifact_directory_for_job(job)))
        assert path.name == "result.png"

    def test_job_artifact_metadata(self):
        user = get_user_model().objects.create_user(username="analyst3")
        job = Job.objects.create(
            owner=user,
            original_prompt="prompt",
            resolved_dataset="dataset",
            backend_profile="rdf",
        )
        artifact = JobArtifact.objects.create(
            job=job,
            artifact_kind="plot",
            path="/artifacts/job-1/result.png",
            is_canonical=True,
        )
        assert artifact.is_canonical is True
        assert artifact.job == job

    def test_backend_command_uses_configured_docker_image(self):
        user = get_user_model().objects.create_user(username="docker-user")
        job = Job.objects.create(
            owner=user,
            original_prompt="prompt",
            resolved_dataset="dataset",
            backend_profile="rdf",
            status=JobStatus.RUNNING,
        )
        with patch.object(services.settings, "HEP_DATA_LLM_DOCKER_IMAGE", "custom/image:tag"):
            command = services._backend_command_for_job(
                job, services.artifact_path_for_job(job, "result.md")
            )
        assert "--docker-image" in command
        assert "custom/image:tag" in command

    def test_run_backend_job_keeps_current_home_when_no_override_is_configured(self):
        user = get_user_model().objects.create_user(username="local-user")
        job = Job.objects.create(
            owner=user,
            original_prompt="prompt",
            resolved_dataset="dataset",
            backend_profile="rdf",
            status=JobStatus.RUNNING,
        )
        completed = subprocess.CompletedProcess(args=["dummy"], returncode=0, stdout="", stderr="")
        with patch.dict(
            os.environ,
            {"HOME": "/real/home", "USERPROFILE": "C:\\Users\\real"},
            clear=False,
        ):
            with patch.object(services.settings, "HEP_DATA_LLM_HOME_DIR", ""):
                with patch("portal.services.subprocess.run", return_value=completed) as mock_run:
                    services.run_backend_job(job)

        env = mock_run.call_args.kwargs["env"]
        assert env["HOME"] == "/real/home"
        assert env["USERPROFILE"] == "C:\\Users\\real"

    def test_run_backend_job_overrides_home_when_configured(self):
        user = get_user_model().objects.create_user(username="docker-user-2")
        job = Job.objects.create(
            owner=user,
            original_prompt="prompt",
            resolved_dataset="dataset",
            backend_profile="rdf",
            status=JobStatus.RUNNING,
        )
        completed = subprocess.CompletedProcess(args=["dummy"], returncode=0, stdout="", stderr="")
        with patch.dict(
            os.environ,
            {"HOME": "/real/home", "USERPROFILE": "C:\\Users\\real"},
            clear=False,
        ):
            with patch.object(services.settings, "HEP_DATA_LLM_HOME_DIR", "/host-home"):
                with patch("portal.services.subprocess.run", return_value=completed) as mock_run:
                    services.run_backend_job(job)

        env = mock_run.call_args.kwargs["env"]
        assert env["HOME"] == "/host-home"
        assert env["USERPROFILE"] == "/host-home"
