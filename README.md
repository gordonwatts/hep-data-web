# HEP Data LLM Web

Lightweight Django frontend for the `hep-data-llm` workflow.

## Development

```powershell
uv sync --extra dev
uv run python manage.py migrate
uv run python manage.py runserver
```

## Tests

```powershell
uv run pytest
uv run ruff check .
uv run ruff format --check .
```

