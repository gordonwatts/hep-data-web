from datetime import timedelta
from pathlib import Path
from tempfile import TemporaryDirectory
from unittest.mock import patch

from django.contrib.auth import get_user_model
from django.core.management import call_command
from django.test import TestCase
from django.utils import timezone

from portal import services
from portal.models import Job, JobStatus


class WorkerServiceTests(TestCase):
    def setUp(self):
        self.user = get_user_model().objects.create_user(username="worker")

    def test_claim_next_queued_job_claims_oldest_and_reorders_queue(self):
        first = Job.objects.create(
            owner=self.user,
            original_prompt="first",
            resolved_dataset="dataset",
            backend_profile="rdf",
            status=JobStatus.QUEUED,
            submitted_at=timezone.now() - timedelta(minutes=2),
        )
        second = Job.objects.create(
            owner=self.user,
            original_prompt="second",
            resolved_dataset="dataset",
            backend_profile="rdf",
            status=JobStatus.QUEUED,
            submitted_at=timezone.now() - timedelta(minutes=1),
        )

        claimed = services.claim_next_queued_job()

        self.assertEqual(claimed.pk, first.pk)
        first.refresh_from_db()
        second.refresh_from_db()
        self.assertEqual(first.status, JobStatus.RUNNING)
        self.assertEqual(first.queue_position, 1)
        self.assertEqual(second.queue_position, 2)

    def test_process_job_marks_completion_and_records_artifacts(self):
        job = Job.objects.create(
            owner=self.user,
            original_prompt="prompt",
            resolved_dataset="dataset",
            backend_profile="rdf",
            status=JobStatus.RUNNING,
            started_at=timezone.now() - timedelta(seconds=10),
            queue_position=1,
        )
        with TemporaryDirectory() as temp_dir:
            output_dir = Path(temp_dir)
            report_path = output_dir / "result.md"
            report_path.write_text(
                "## Result\n\n```python\nprint('hello world')\n```\n",
                encoding="utf-8",
            )
            image_path = output_dir / "plot.png"
            image_path.write_bytes(b"png")

            def fake_executor(_job):
                return services.JobExecutionResult(
                    output_path=report_path,
                    generated_code="print('hello world')",
                    stdout="stdout",
                    stderr="",
                    exit_code=0,
                    artifact_paths=(report_path, image_path),
                    metadata={"returncode": 0},
                )

            updated = services.process_job(job, executor=fake_executor)

        updated.refresh_from_db()
        self.assertEqual(updated.status, JobStatus.COMPLETED)
        self.assertEqual(updated.generated_code, "print('hello world')")
        self.assertEqual(updated.artifacts.count(), 2)
        self.assertTrue(updated.artifacts.filter(is_canonical=True).exists())

    def test_process_job_marks_failure_on_executor_exception(self):
        job = Job.objects.create(
            owner=self.user,
            original_prompt="prompt",
            resolved_dataset="dataset",
            backend_profile="rdf",
            status=JobStatus.RUNNING,
            started_at=timezone.now() - timedelta(seconds=10),
            queue_position=1,
        )

        def fake_executor(_job):
            raise RuntimeError("boom")

        updated = services.process_job(job, executor=fake_executor)

        updated.refresh_from_db()
        self.assertEqual(updated.status, JobStatus.FAILED)
        self.assertIn("boom", updated.failure_message)

    def test_start_queued_job_rejects_nonqueued_jobs(self):
        job = Job.objects.create(
            owner=self.user,
            original_prompt="prompt",
            resolved_dataset="dataset",
            backend_profile="rdf",
            status=JobStatus.COMPLETED,
        )

        with self.assertRaisesMessage(ValueError, "Job must be queued before it can start"):
            services.start_queued_job(job)


class SmokeCommandTests(TestCase):
    def test_run_smoke_job_creates_and_processes_job(self):
        get_user_model().objects.create_user(username="smoke")

        def fake_create_job(**kwargs):
            job = Job.objects.create(
                owner=kwargs["owner"],
                original_prompt=kwargs["prompt"],
                resolved_dataset=kwargs["dataset"] or "dataset",
                backend_profile=kwargs["backend_profile"],
                status=JobStatus.QUEUED,
            )
            return job

        def fake_process_job(job, executor=None):
            job.status = JobStatus.COMPLETED
            job.generated_code = "print('ok')"
            job.save(update_fields=["status", "generated_code"])
            return job

        with (
            patch(
                "portal.management.commands.run_smoke_job.services.create_job",
                side_effect=fake_create_job,
            ),
            patch(
                "portal.management.commands.run_smoke_job.services.process_job",
                side_effect=fake_process_job,
            ),
            patch(
                "portal.management.commands.run_smoke_job.load_example_questions",
                return_value=[],
            ),
        ):
            call_command(
                "run_smoke_job",
                prompt="Plot ETmiss",
                dataset="",
                username="smoke",
                verbosity=0,
            )

        self.assertTrue(
            Job.objects.filter(owner__username="smoke", status=JobStatus.COMPLETED).exists()
        )
