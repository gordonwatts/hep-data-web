#!/usr/bin/env python
"""Django's command-line utility for administrative tasks."""

import os
import sys

from hep_data_web.env import load_env_file


def main() -> None:
    load_env_file()
    os.environ.setdefault("DJANGO_SETTINGS_MODULE", "hep_data_web.settings.dev")
    from django.core.management import execute_from_command_line

    execute_from_command_line(sys.argv)


if __name__ == "__main__":
    main()
