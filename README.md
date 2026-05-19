# HEP Data LLM Web

Lightweight Django frontend for the `hep-data-llm` workflow.

## Development

```powershell
uv sync --extra dev
copy .env.example .env
uv run python manage.py migrate
uv run python manage.py runserver
```

The default settings module is `hep_data_web.settings.dev`. For production-style
deployment, set `DJANGO_SETTINGS_MODULE=hep_data_web.settings.prod`.

## Worker

Run the queue worker in a second shell:

```powershell
uv run python manage.py run_worker
```

The worker claims one queued job at a time and writes result artifacts under the
persistent media directory.

To create and execute a single smoke-test job against the backend:

```powershell
uv run python manage.py run_smoke_job
```

## Local Login

The app uses Django's built-in login views for now. Create a user with:

```powershell
uv run python manage.py createsuperuser
```

Then log in at `/accounts/login/` and submit jobs from the homepage.

## Tests

```powershell
uv run pytest
uv run ruff check .
uv run ruff format --check .
```
