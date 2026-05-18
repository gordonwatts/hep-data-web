"""ASGI config for hep_data_web."""

import os

from django.core.asgi import get_asgi_application

os.environ.setdefault("DJANGO_SETTINGS_MODULE", "hep_data_web.settings.dev")

application = get_asgi_application()
