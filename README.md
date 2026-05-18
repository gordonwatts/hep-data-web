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

## Tests

```powershell
uv run pytest
uv run ruff check .
uv run ruff format --check .
```
