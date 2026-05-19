from random import sample

from django.shortcuts import render
from django.utils import timezone

from portal.backend import available_profile_choices, load_example_questions
from portal.models import Job


def featured_example_questions():
    example_questions = load_example_questions()
    if len(example_questions) <= 3:
        return example_questions
    return sample(example_questions, 3)


def home(request):
    history_rows = []
    if request.user.is_authenticated:
        jobs = (
            Job.objects.filter(owner=request.user)
            .select_related("owner")
            .order_by("-submitted_at", "-pk")[:10]
        )
        history_rows = [
            {
                "job": job,
                "submitted_at": timezone.localtime(job.submitted_at),
                "status_label": job.get_status_display(),
                "badge_class": {
                    "queued": "text-bg-secondary",
                    "running": "text-bg-primary",
                    "completed": "text-bg-success",
                    "failed": "text-bg-danger",
                    "cancelled": "text-bg-warning",
                }.get(job.status, "text-bg-secondary"),
            }
            for job in jobs
        ]

    return render(
        request,
        "portal/home.html",
        {
            "page_title": "HEP Data LLM",
            "example_questions": featured_example_questions(),
            "profile_choices": available_profile_choices(),
            "history_rows": history_rows,
        },
    )
