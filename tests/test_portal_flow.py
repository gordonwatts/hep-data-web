from unittest.mock import patch

from django.contrib.auth import get_user_model
from django.test import TestCase
from django.urls import reverse

from portal.models import Job, JobStatus


class PortalFlowTests(TestCase):
    def setUp(self):
        user_model = get_user_model()
        self.owner = user_model.objects.create_user(username="owner", password="secret")
        self.other = user_model.objects.create_user(username="other", password="secret")

    def test_submit_job_redirects_to_result_page(self):
        self.client.force_login(self.owner)

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

        self.client.force_login(self.other)
        response = self.client.get(
            reverse("job-detail", kwargs={"submission_id": job.submission_id})
        )
        self.assertEqual(response.status_code, 404)

        self.client.force_login(self.owner)
        response = self.client.get(
            reverse("job-detail", kwargs={"submission_id": job.submission_id})
        )
        self.assertContains(response, "Job result")
        self.assertContains(response, "Generated code")

    def test_clone_job_creates_new_submission_with_edited_prompt(self):
        source_job = Job.objects.create(
            owner=self.owner,
            original_prompt="Plot ETmiss",
            resolved_dataset="dataset",
            backend_profile="rdf",
            status=JobStatus.COMPLETED,
        )
        self.client.force_login(self.owner)

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
