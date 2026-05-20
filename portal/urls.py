from django.urls import path

from . import views

urlpatterns = [
    path("accounts/login/", views.login, name="login"),
    path("accounts/github/login/", views.github_login, name="github-login"),
    path("accounts/github/callback/", views.github_callback, name="github-callback"),
    path("accounts/status/", views.auth_status, name="auth-status"),
    path("accounts/logout/", views.logout, name="logout"),
    path("admin/users/", views.admin_users, name="admin-users"),
    path(
        "admin/users/<int:profile_id>/<str:decision>/",
        views.admin_user_decision,
        name="admin-user-decision",
    ),
    path("", views.home, name="home"),
    path("submit/", views.submit_job, name="submit-job"),
    path("jobs/<uuid:submission_id>/", views.job_detail, name="job-detail"),
    path(
        "jobs/<uuid:submission_id>/status/",
        views.job_detail_partial,
        name="job-detail-status",
    ),
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
