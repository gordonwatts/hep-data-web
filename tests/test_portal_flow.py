from datetime import timedelta
from unittest.mock import patch

from django.contrib.auth import get_user_model
from django.test import TestCase
from django.urls import reverse
from django.utils import timezone

from portal.auth import SESSION_APPROVED_LOGIN_KEY
from portal.models import ApprovalState, Job, JobArtifact, JobStatus, get_or_create_profile_for_user


class PortalFlowTests(TestCase):
    def setUp(self):
        user_model = get_user_model()
        self.owner = user_model.objects.create_user(username="owner", password="secret")
        self.other = user_model.objects.create_user(username="other", password="secret")

    def _force_approved_login(self, user):
        profile = get_or_create_profile_for_user(user)
        profile.approval_state = ApprovalState.APPROVED
        profile.save(update_fields=["approval_state"])
        self.client.force_login(user)
        session = self.client.session
        session[SESSION_APPROVED_LOGIN_KEY] = True
        session.save()

    def test_submit_job_redirects_to_result_page(self):
        self._force_approved_login(self.owner)

        with patch("portal.services.default_dataset", return_value="default-dataset"):
            response = self.client.post(
                reverse("submit-job"),
                {
                    "prompt": "Plot the leading jet pT",
                    "dataset": "",
                    "profile": "rdf",
                },
            )

        self.assertEqual(response.status_code, 302)
        job = Job.objects.get(owner=self.owner)
        self.assertEqual(job.original_prompt, "Plot the leading jet pT")
        self.assertEqual(job.backend_profile, "rdf")
        self.assertEqual(job.resolved_dataset, "default-dataset")
        self.assertRedirects(
            response,
            reverse("job-detail", kwargs={"submission_id": job.submission_id}),
            fetch_redirect_response=False,
        )

    def test_job_detail_enforces_owner_visibility(self):
        job = Job.objects.create(
            owner=self.owner,
            original_prompt="Plot ETmiss",
            resolved_dataset="dataset",
            backend_profile="rdf",
            status=JobStatus.COMPLETED,
        )

        self._force_approved_login(self.other)
        response = self.client.get(
            reverse("job-detail", kwargs={"submission_id": job.submission_id})
        )
        self.assertEqual(response.status_code, 404)

        self._force_approved_login(self.owner)
        response = self.client.get(
            reverse("job-detail", kwargs={"submission_id": job.submission_id})
        )
        self.assertContains(response, "Job result")
        self.assertContains(response, "Generated code")

    def test_job_detail_renders_machine_readable_timestamps(self):
        job = Job.objects.create(
            owner=self.owner,
            original_prompt="Plot ETmiss",
            resolved_dataset="dataset",
            backend_profile="rdf",
            status=JobStatus.COMPLETED,
            started_at=timezone.now() - timedelta(minutes=3),
            completed_at=timezone.now() - timedelta(minutes=1),
        )
        self._force_approved_login(self.owner)

        response = self.client.get(
            reverse("job-detail", kwargs={"submission_id": job.submission_id})
        )

        self.assertContains(response, "<time", html=False)
        self.assertContains(response, 'datetime="', html=False)
        self.assertContains(response, "UTC")
        self.assertContains(response, "* 1000", html=False)

    def test_job_detail_partial_enforces_owner_visibility(self):
        job = Job.objects.create(
            owner=self.owner,
            original_prompt="Plot ETmiss",
            resolved_dataset="dataset",
            backend_profile="rdf",
            status=JobStatus.RUNNING,
            started_at=timezone.now() - timedelta(minutes=2),
            queue_position=1,
        )

        self._force_approved_login(self.other)
        response = self.client.get(
            reverse("job-detail-status", kwargs={"submission_id": job.submission_id})
        )
        self.assertEqual(response.status_code, 404)

        self._force_approved_login(self.owner)
        response = self.client.get(
            reverse("job-detail-status", kwargs={"submission_id": job.submission_id})
        )
        self.assertContains(response, "Running")
        self.assertContains(response, 'data-terminal="false"', html=False)

    def test_job_detail_partial_renders_queued_state(self):
        job = Job.objects.create(
            owner=self.owner,
            original_prompt="Plot ETmiss",
            resolved_dataset="dataset",
            backend_profile="rdf",
            status=JobStatus.QUEUED,
            queue_position=1,
        )
        self._force_approved_login(self.owner)

        response = self.client.get(
            reverse("job-detail-status", kwargs={"submission_id": job.submission_id})
        )

        self.assertContains(response, "Queued")
        self.assertContains(response, 'data-terminal="false"', html=False)

    def test_job_detail_partial_renders_terminal_state_and_artifacts(self):
        job = Job.objects.create(
            owner=self.owner,
            original_prompt="Plot ETmiss",
            resolved_dataset="dataset",
            backend_profile="rdf",
            status=JobStatus.COMPLETED,
            generated_code="print('ok')",
            started_at=timezone.now() - timedelta(minutes=3),
            completed_at=timezone.now() - timedelta(minutes=1),
        )
        JobArtifact.objects.create(
            job=job,
            artifact_kind="report",
            path="/tmp/report.md",
            is_canonical=True,
        )
        self._force_approved_login(self.owner)

        response = self.client.get(
            reverse("job-detail-status", kwargs={"submission_id": job.submission_id})
        )

        self.assertContains(response, "Completed")
        self.assertContains(response, "Download report")
        self.assertContains(response, "print(&#x27;ok&#x27;)", html=False)
        self.assertContains(response, 'data-terminal="true"', html=False)

    def test_job_detail_partial_renders_failed_state(self):
        job = Job.objects.create(
            owner=self.owner,
            original_prompt="Plot ETmiss",
            resolved_dataset="dataset",
            backend_profile="rdf",
            status=JobStatus.FAILED,
            failure_message="boom",
            started_at=timezone.now() - timedelta(minutes=3),
            completed_at=timezone.now() - timedelta(minutes=1),
        )
        self._force_approved_login(self.owner)

        response = self.client.get(
            reverse("job-detail-status", kwargs={"submission_id": job.submission_id})
        )

        self.assertContains(response, "Failed")
        self.assertContains(response, "boom")
        self.assertContains(response, 'data-terminal="true"', html=False)

    def test_clone_job_creates_new_submission_with_edited_prompt(self):
        source_job = Job.objects.create(
            owner=self.owner,
            original_prompt="Plot ETmiss",
            resolved_dataset="dataset",
            backend_profile="rdf",
            status=JobStatus.COMPLETED,
        )
        self._force_approved_login(self.owner)

        response = self.client.post(
            reverse("job-clone", kwargs={"submission_id": source_job.submission_id}),
            {
                "prompt": "Plot the leading jet pT",
                "dataset": "dataset",
                "profile": "servicex_awkward",
            },
        )

        self.assertEqual(response.status_code, 302)
        cloned = Job.objects.exclude(pk=source_job.pk).get(owner=self.owner)
        self.assertEqual(cloned.original_prompt, "Plot the leading jet pT")
        self.assertEqual(cloned.backend_profile, "servicex_awkward")
        self.assertRedirects(
            response,
            reverse("job-detail", kwargs={"submission_id": cloned.submission_id}),
            fetch_redirect_response=False,
        )
