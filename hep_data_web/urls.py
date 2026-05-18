"""URL configuration for hep_data_web."""

from django.contrib import admin
from django.urls import include, path

urlpatterns = [
    path("admin/", admin.site.urls),
    path("", include("portal.urls")),
]
