import os
import subprocess
import tempfile
from datetime import timedelta
from pathlib import Path
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

    def test_create_job_prefers_dataset_from_prompt(self):
        services.default_dataset = lambda: "default-dataset"  # type: ignore[assignment]

        job = services.create_job(
            owner=self.user,
            prompt="Plot ETmiss from rucio dataset prompt-dataset",
            dataset="form-dataset",
            backend_profile="rdf",
        )

        self.assertEqual(job.resolved_dataset, "prompt-dataset")

    def test_create_job_uses_form_dataset_when_prompt_is_missing_one(self):
        services.default_dataset = lambda: "default-dataset"  # type: ignore[assignment]

        job = services.create_job(
            owner=self.user,
            prompt="plot the leading jet",
            dataset="form-dataset",
            backend_profile="rdf",
        )

        self.assertEqual(job.resolved_dataset, "form-dataset")

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
        with patch.object(services.settings, "HEP_DATA_LLM_RDF_DOCKER_IMAGE", "custom/image:tag"):
            with patch.object(services.settings, "HEP_DATA_LLM_MODEL", "custom-model"):
                with patch.object(services.settings, "HEP_DATA_LLM_REPAIR_CYCLES", 4):
                    command = services._backend_command_for_job(
                        job, services.artifact_path_for_job(job, "result.md")
                    )
        assert "--docker-image" in command
        assert "custom/image:tag" in command
        assert "--models" in command
        assert "custom-model" in command
        assert "--n-iter" in command
        assert "4" in command

    def test_backend_command_omits_docker_image_when_not_configured(self):
        user = get_user_model().objects.create_user(username="no-docker-user")
        job = Job.objects.create(
            owner=user,
            original_prompt="prompt",
            resolved_dataset="dataset",
            backend_profile="rdf",
            status=JobStatus.RUNNING,
        )
        with (
            patch.object(services.settings, "HEP_DATA_LLM_RDF_DOCKER_IMAGE", ""),
            patch.object(services.settings, "HEP_DATA_LLM_DOCKER_IMAGE_GLOBAL_FALLBACK", ""),
            patch.object(services.settings, "HEP_DATA_LLM_DOCKER_IMAGE", ""),
        ):
            command = services._backend_command_for_job(
                job, services.artifact_path_for_job(job, "result.md")
            )
        assert "--docker-image" not in command

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

    def test_run_backend_job_writes_openai_key_to_visible_env_files(self):
        user = get_user_model().objects.create_user(username="env-user")
        job = Job.objects.create(
            owner=user,
            original_prompt="prompt",
            resolved_dataset="dataset",
            backend_profile="rdf",
            status=JobStatus.RUNNING,
        )
        completed = subprocess.CompletedProcess(args=["dummy"], returncode=0, stdout="", stderr="")

        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = Path(temp_dir)
            base_dir = temp_path / "app"
            home_dir = temp_path / "home"
            artifact_root = temp_path / "artifacts"
            base_dir.mkdir()
            home_dir.mkdir()

            with patch.dict(
                os.environ,
                {"api_openai_com_API_KEY": "outer-secret"},
                clear=False,
            ):
                with patch.object(services.settings, "BASE_DIR", base_dir):
                    with patch.object(services.settings, "ARTIFACT_ROOT", artifact_root):
                        with patch.object(
                            services.settings,
                            "HEP_DATA_LLM_HOME_DIR",
                            str(home_dir),
                        ):
                            with patch(
                                "portal.services.subprocess.run", return_value=completed
                            ):
                                services.run_backend_job(job)

            base_env = (base_dir / ".env").read_text(encoding="utf-8")
            home_env = (home_dir / ".env").read_text(encoding="utf-8")

        assert "api_openai_com_API_KEY=outer-secret" in base_env
        assert "OPENAI_API_KEY=outer-secret" in base_env
        assert "api_openai_com_API_KEY=outer-secret" in home_env
        assert "OPENAI_API_KEY=outer-secret" in home_env

    def test_run_backend_job_collects_nested_png_artifacts(self):
        user = get_user_model().objects.create_user(username="nested-image-user")
        job = Job.objects.create(
            owner=user,
            original_prompt="prompt",
            resolved_dataset="dataset",
            backend_profile="rdf",
            status=JobStatus.RUNNING,
        )
        completed = subprocess.CompletedProcess(args=["dummy"], returncode=0, stdout="", stderr="")

        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = Path(temp_dir)
            base_dir = temp_path / "app"
            home_dir = temp_path / "home"
            artifact_root = temp_path / "artifacts"
            base_dir.mkdir()
            home_dir.mkdir()

            def fake_run(command, **kwargs):
                output_path = Path(command[5])
                output_path.parent.mkdir(parents=True, exist_ok=True)
                output_path.write_text(
                    "## Result\n\n```python\nprint('hello world')\n```\n",
                    encoding="utf-8",
                )
                nested_png = output_path.parent / "img" / "nested" / "plot.png"
                nested_png.parent.mkdir(parents=True, exist_ok=True)
                nested_png.write_bytes(b"png")
                return completed

            with patch.dict(
                os.environ,
                {"api_openai_com_API_KEY": "outer-secret"},
                clear=False,
            ):
                with patch.object(services.settings, "BASE_DIR", base_dir):
                    with patch.object(services.settings, "ARTIFACT_ROOT", artifact_root):
                        with patch.object(
                            services.settings,
                            "HEP_DATA_LLM_HOME_DIR",
                            str(home_dir),
                        ):
                            with patch("portal.services.subprocess.run", side_effect=fake_run):
                                result = services.run_backend_job(job)

        artifact_paths = [str(path) for path in result.artifact_paths]
        assert any(path.endswith("result.md") for path in artifact_paths)
        assert any(path.endswith(r"img\nested\plot.png") for path in artifact_paths)
        assert any(
            Path(path).parts[-3:] == ("img", "nested", "plot.png")
            for path in result.metadata["image_paths"]
        )
