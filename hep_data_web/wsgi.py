"""WSGI config for hep_data_web."""

import os

from django.core.wsgi import get_wsgi_application

from hep_data_web.env import load_env_file

load_env_file()
os.environ.setdefault("DJANGO_SETTINGS_MODULE", "hep_data_web.settings.dev")

application = get_wsgi_application()
