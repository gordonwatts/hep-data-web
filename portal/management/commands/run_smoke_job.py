from __future__ import annotations

from django.contrib.auth import get_user_model
from django.core.management.base import BaseCommand

from portal import services
from portal.backend import available_profile_choices, load_example_questions


class Command(BaseCommand):
    help = "Create and execute one smoke-test job against the backend."

    def add_arguments(self, parser):
        parser.add_argument(
            "--username",
            default="smoke",
            help="Username to associate with the smoke job.",
        )
        parser.add_argument(
            "--prompt",
            default="",
            help="Prompt to submit. Defaults to the first bundled example question.",
        )
        parser.add_argument(
            "--dataset",
            default="",
            help="Optional dataset override. Leave blank to use the default backend dataset.",
        )
        parser.add_argument(
            "--profile",
            default=str(available_profile_choices()[0].value),
            choices=[str(choice.value) for choice in available_profile_choices()],
            help="Backend profile to use.",
        )

    def handle(self, *args, **options):
        prompt = options["prompt"].strip()
        if not prompt:
            questions = load_example_questions()
            if not questions:
                raise RuntimeError("No bundled example questions were found")
            prompt = questions[0].prompt

        dataset = options["dataset"].strip() or None
        profile = options["profile"]
        username = options["username"]

        user_model = get_user_model()
        user, _ = user_model.objects.get_or_create(username=username)

        job = services.create_job(
            owner=user,
            prompt=prompt,
            dataset=dataset,
            backend_profile=profile,
        )
        self.stdout.write(f"Queued smoke job {job.submission_id}.")

        job = services.start_queued_job(job)
        self.stdout.write(f"Started smoke job {job.submission_id}.")

        job = services.process_job(job)
        self.stdout.write(
            f"Completed smoke job {job.submission_id} with status {job.get_status_display()}."
        )
        self.stdout.write(f"Artifacts: {job.artifacts.count()}")
