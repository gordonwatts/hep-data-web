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
On `docker compose up`, the stack also runs migrations automatically before the web
and worker services start.

```powershell
copy .env.example .env
docker compose up --build
```

Once the stack is up, you can smoke-test the backend from inside the container:

```powershell
docker compose exec web uv run python manage.py run_smoke_job
```

If the backend image is not already available on your machine, set
`HEP_DATA_LLM_SERVICEX_AWKWARD_DOCKER_IMAGE` or
`HEP_DATA_LLM_RDF_DOCKER_IMAGE` in `.env` for the profile you want the worker to use.
The ServiceX + Awkward profile is the default for the homepage selector.

When running the worker locally on your machine, it uses your normal home
directory so `~/servicex.yaml` works as expected. The `HEP_DATA_LLM_HOME_DIR`
override is only needed when you want to point the backend at a different home
directory, such as the mounted path inside Docker Compose.

## Local Login

GitHub OAuth is the default login flow. Put your local development secrets in the
repository root `.env` file, then configure your GitHub OAuth app to use:

- Authorization callback URL: `http://localhost:8000/accounts/github/callback/`
- Scopes: `read:user` and `user:email`

The minimum `.env` entries for login are:

```powershell
GITHUB_CLIENT_ID=...
GITHUB_CLIENT_SECRET=...
ADMIN_EMAILS=...
```

The app sends approval notifications to the addresses listed in `ADMIN_EMAILS`.
For local manual testing you can still create a Django superuser for the built-in
admin site, which now lives at `/admin-panel/`.

```powershell
uv run python manage.py createsuperuser
```

If you are running the Docker Compose stack, use:

```powershell
docker compose up --build
```

Then, in a second shell:

```powershell
docker compose exec web uv run python manage.py createsuperuser
```

## Tests

```powershell
uv run pytest
uv run ruff check .
uv run ruff format --check .
```

GitHub Actions runs the same test, lint, and formatting checks on pull requests
and pushes to `main`.

For the release image workflow, configure these repository secrets:

- `REGISTRY_SERVER`
- `REGISTRY_USERNAME`
- `REGISTRY_PASSWORD`
- `IMAGE_NAME`
