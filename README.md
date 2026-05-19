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

## Docker

The Compose stack includes `web`, `worker`, `postgres`, and a local Docker daemon
for backend job execution.

```powershell
copy .env.example .env
docker compose up --build
```

Once the stack is up, you can smoke-test the backend from inside the container:

```powershell
docker compose exec web uv run python manage.py run_smoke_job
```

If the backend image is not already available on your machine, set
`HEP_DATA_LLM_DOCKER_IMAGE` in `.env` to the image tag you want the worker to use.

When running the worker locally on your machine, it uses your normal home
directory so `~/servicex.yaml` works as expected. The `HEP_DATA_LLM_HOME_DIR`
override is only needed when you want to point the backend at a different home
directory, such as the mounted path inside Docker Compose.

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
