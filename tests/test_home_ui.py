from unittest.mock import patch

from django.contrib.auth import get_user_model
from django.test import TestCase

from portal.backend import ExampleQuestion
from portal.models import Job, JobStatus


class HomePageUITests(TestCase):
    def test_home_page_shows_example_prompts(self):
        with patch(
            "portal.views.load_example_questions",
            return_value=[ExampleQuestion(prompt="Plot ETmiss", title="ETmiss")],
        ):
            response = self.client.get("/")

        self.assertContains(response, "Example prompts")
        self.assertContains(response, "ETmiss")

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
            self.client.force_login(user)

            response = self.client.get("/")

        self.assertContains(response, "Your history")
        self.assertContains(response, "Make a histogram of ETmiss")
        self.assertContains(response, "Running")
