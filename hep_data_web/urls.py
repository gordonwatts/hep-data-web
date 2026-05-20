"""URL configuration for hep_data_web."""

from django.contrib import admin
from django.urls import include, path

urlpatterns = [
    path("", include("portal.urls")),
    path("admin-panel/", admin.site.urls),
]
