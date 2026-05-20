from unittest.mock import patch

from django.contrib.auth import get_user_model
from django.test import TestCase

from portal.auth import SESSION_APPROVED_LOGIN_KEY
from portal.backend import ExampleQuestion
from portal.models import ApprovalState, Job, JobStatus, get_or_create_profile_for_user


class HomePageUITests(TestCase):
    def _force_approved_login(self, user):
        profile = get_or_create_profile_for_user(user)
        profile.approval_state = ApprovalState.APPROVED
        profile.save(update_fields=["approval_state"])
        self.client.force_login(user)
        session = self.client.session
        session[SESSION_APPROVED_LOGIN_KEY] = True
        session.save()

    def test_home_page_shows_example_prompts(self):
        with patch(
            "portal.views.load_example_questions",
            return_value=[ExampleQuestion(prompt="Plot ETmiss", title="ETmiss")],
        ):
            response = self.client.get("/")

        self.assertContains(response, "Example prompts")
        self.assertContains(response, "ETmiss")

    def test_home_page_truncates_long_example_prompts(self):
        long_prompt = (
            "Plot the distribution of missing transverse energy for the full dataset "
            "with a detailed breakdown by lepton flavor, jet multiplicity, and event "
            "selection in a way that stays readable in the prompt list."
        )
        with patch(
            "portal.views.load_example_questions",
            return_value=[ExampleQuestion(prompt=long_prompt, title=long_prompt)],
        ):
            response = self.client.get("/")

        self.assertContains(response, "example-prompt-text")
        self.assertContains(response, "title=")
        self.assertContains(response, long_prompt)

    def test_home_page_shows_only_three_random_examples(self):
        with (
            patch(
                "portal.views.load_example_questions",
                return_value=[
                    ExampleQuestion(prompt="Prompt 1", title="One"),
                    ExampleQuestion(prompt="Prompt 2", title="Two"),
                    ExampleQuestion(prompt="Prompt 3", title="Three"),
                    ExampleQuestion(prompt="Prompt 4", title="Four"),
                ],
            ),
            patch(
                "portal.views.sample",
                return_value=[
                    ExampleQuestion(prompt="Prompt 2", title="Two"),
                    ExampleQuestion(prompt="Prompt 4", title="Four"),
                    ExampleQuestion(prompt="Prompt 1", title="One"),
                ],
            ) as sample_mock,
        ):
            response = self.client.get("/")

        sample_mock.assert_called_once()
        self.assertContains(response, "One")
        self.assertContains(response, "Two")
        self.assertContains(response, "Four")
        self.assertNotContains(response, "Three")

    def test_home_page_shows_logged_in_user_history(self):
        with patch("portal.views.load_example_questions", return_value=[]):
            user = get_user_model().objects.create_user(username="viewer")
            Job.objects.create(
                owner=user,
                original_prompt="Make a histogram of ETmiss",
                resolved_dataset="dataset",
                backend_profile="rdf",
                status=JobStatus.RUNNING,
            )
            self._force_approved_login(user)

            response = self.client.get("/")

        self.assertContains(response, "Your history")
        self.assertContains(response, "Make a histogram of ETmiss")
        self.assertContains(response, "Running")
