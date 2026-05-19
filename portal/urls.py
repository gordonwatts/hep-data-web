from django.urls import path

from . import views

urlpatterns = [
    path("", views.home, name="home"),
    path("submit/", views.submit_job, name="submit-job"),
    path("jobs/<uuid:submission_id>/", views.job_detail, name="job-detail"),
    path("jobs/<uuid:submission_id>/clone/", views.clone_job, name="job-clone"),
    path(
        "jobs/<uuid:submission_id>/artifacts/<int:artifact_id>/",
        views.job_artifact_inline,
        name="job-artifact-inline",
    ),
    path(
        "jobs/<uuid:submission_id>/artifacts/<int:artifact_id>/download/",
        views.job_artifact_download,
        name="job-artifact-download",
    ),
]
