# GitHub Issues Follow-up Implementation Plan

## Summary

Implement the follow-up behavior from `docs/2026-05-20-github-issues-spec.md` as small, reviewable changes on top of the current Django monolith.

The current project already has:

- Django settings, templates, routes, models, and tests.
- `portal.backend` as the `hep-data-llm` adapter boundary.
- `portal.services` as the queue, job lifecycle, artifact, and backend execution layer.
- `portal.views` as the server-rendered page layer.
- `run_worker` as a management command outside HTTP request handling.
- Bootstrap 5.3 templates following the Quiet Scientific Portal theme.
- No GitHub Actions workflows yet.
- No Azure deployment scripts yet.

This plan keeps the existing architecture. Do not execute analysis work from HTTP request handlers. Keep all backend-specific options behind `portal.backend` and `portal.services`.

## Chosen Defaults

- **Plan file:** this file is the checklist for the GitHub issues follow-up.
- **Framework:** keep Django server-rendered templates.
- **Live updates:** use lightweight HTMX-style partial polling or a tiny fetch-based script if adding HTMX is not desired. Prefer HTMX if adding one browser dependency is acceptable.
- **Timestamp localization:** render UTC ISO timestamps in HTML and localize in browser JavaScript. Keep readable UTC fallback text for no-JavaScript users.
- **Dataset fallback:** store a fallback dataset on `Job.resolved_dataset`, but send it to the backend as conditional instruction text rather than as an unconditional override.
- **Backend defaults:** default web config to `gpt-5.4-mini`; pass CLI value `gpt-54-mini` to `hep-data-llm`.
- **Repair/retry cycles:** default to `10`.
- **Docker image config:** make image overrides profile-specific. Keep legacy global image only as an explicitly named fallback if needed.
- **Worker crash recovery:** reuse `failed`; do not add a `crashed` status.
- **Azure scripts:** use PowerShell scripts because the repo and current environment are Windows-oriented, but keep commands standard Azure CLI where possible.
- **CI:** use GitHub Actions with `uv run pytest`, `uv run ruff check .`, and `uv run ruff format --check .`.

## Public Interfaces / Core Concepts

### Existing files to extend

- `hep_data_web/settings/base.py`
  - Add new environment-driven settings for backend model, repair cycles, and per-profile Docker images.
- `.env.example`
  - Document every new setting.
- `portal/backend.py`
  - Add adapter helpers for prompt fallback construction, backend model CLI value, repair-cycle count, and profile-specific Docker image selection.
- `portal/services.py`
  - Use the adapter helpers in `_backend_command_for_job`.
  - Add stale-running-job recovery and terminal failure handling.
  - Keep queue state transitions explicit and persistent.
- `portal/management/commands/run_worker.py`
  - Run startup recovery before the polling loop.
- `portal/views.py`
  - Refresh approval state on account status page.
  - Add job detail partial endpoint for live polling.
  - Add UTC timestamp context helpers.
- `portal/urls.py`
  - Add the job detail partial route.
- `templates/base.html`
  - Add timestamp localization JavaScript or include HTMX if selected.
- `templates/portal/auth_status.html`
  - Stop telling approved users they must log out and sign in again.
- `templates/portal/home.html`
  - Constrain example prompt display while preserving full text and selection behavior.
  - Add machine-readable timestamps to history if history shows timestamps later.
- `templates/portal/job_detail.html`
  - Split the live status/result area into an include template for full page plus partial polling.
  - Add machine-readable timestamp elements.
- `templates/portal/_job_detail_panel.html`
  - New template include for status, metadata, artifacts, timestamps, failure text, results, and downloads.
- `tests/`
  - Extend existing focused test modules rather than adding broad slow tests.

### New files to add during implementation

- `.github/workflows/ci.yml`
  - Run tests, formatter check, and linter on pull requests and main branch pushes.
- `.github/workflows/release.yml`
  - Opt-in Docker build and push workflow for amd64 and arm64.
- `docs/azure-deployment.md`
  - Operator instructions for Azure setup, teardown, persistence, certificates, registry auth, and admin bootstrap.
- `scripts/azure/create-resources.ps1`
  - Create Azure resources from scratch for a logged-in Azure CLI user.
- `scripts/azure/delete-app-resources.ps1`
  - Delete ephemeral app resources while preserving persistent database/storage resources.
- `scripts/azure/delete-persistent-data.ps1`
  - Explicit destructive deletion of persistent database/storage resources.

## Implementation Checklist

### 1. User Approval Refresh (Issue #11)

- [x] Update `portal.auth.profile_has_app_access` or the `auth_status` view so persisted `APPROVED` state can refresh the session approval flag without a new OAuth login.
  - Current behavior requires both `profile.approval_state == APPROVED` and `SESSION_APPROVED_LOGIN_KEY == True`.
  - Preferred minimal change: in `portal.views.auth_status`, call `profile.refresh_from_db()`, and if `profile.approval_state == ApprovalState.APPROVED`, set `SESSION_APPROVED_LOGIN_KEY = True` and redirect to `home` or render an approved state with a primary link into the app.
  - Keep rejected users blocked and do not set the session flag for rejected profiles.
- [x] Update `templates/portal/auth_status.html`.
  - Remove the message that says approved users must log out and sign in again.
  - For approved users, show a clear primary action to enter the app if the view does not redirect immediately.
  - Keep pending and rejected copy explicit.
- [x] Update `portal.middleware.ApprovalGateMiddleware` only if needed.
  - The middleware currently calls `profile_has_app_access`, so approval refresh should be handled before the user tries protected pages or by making the helper trust persisted approval.
  - If changing the helper to trust persisted approval, verify this does not weaken login semantics. The user is already authenticated, so this is acceptable.
- [x] Replace `tests/test_auth.py::test_admin_can_approve_user_and_user_needs_fresh_login`.
  - New expectation: pending user is approved by admin, refreshes `/accounts/status/`, and can reach `/` without logout.
- [x] Add rejected refresh regression test in `tests/test_auth.py`.
  - Force-login a rejected user with `SESSION_APPROVED_LOGIN_KEY = False`.
  - GET `/accounts/status/`.
  - Assert rejected copy is shown and GET `/` still redirects to `auth-status`.

### 2. Dataset Selection Semantics (Issue #8)

- [x] Replace `portal.backend.render_job_prompt(prompt, dataset)` semantics.
  - Current implementation appends `Dataset to use: <dataset>` if the dataset string is not a substring of the prompt.
  - Required implementation should append conditional fallback text: `If this question does not specify a dataset, use <dataset>.`
  - Keep the exact helper in `portal.backend`; do not move dataset logic into views or worker code.
- [x] Add a small prompt-dataset detector helper in `portal.backend`.
  - Reuse `_dataset_from_prompt` as one detector, but broaden enough for supported tests.
  - Suggested helper: `prompt_mentions_dataset(prompt: str) -> bool`.
  - It can return true for `rucio dataset`, `dataset`, `DAOD`, or explicit known dataset-like strings. Keep it conservative and documented in tests.
- [x] Update `portal.services.create_job`.
  - Preserve `Job.resolved_dataset` as:
    - Prompt-specified dataset if confidently extracted.
    - Form dataset if no prompt dataset.
    - Default dataset if neither prompt nor form dataset.
  - Do not reject submission only because the form dataset is blank.
  - Continue raising if there is no prompt dataset, no form dataset, and no configured default dataset.
- [x] Update `_backend_command_for_job`.
  - The prompt sent to backend should include conditional fallback only when using form/default dataset.
  - If prompt specifies a dataset, pass original prompt unchanged.
- [x] Consider adding one optional field only if necessary.
  - Prefer no migration if the existing `resolved_dataset` can represent the selected fallback or extracted prompt dataset.
  - If tests prove the distinction is ambiguous, add `Job.result_metadata["dataset_source"]` at job creation instead of a new model field.
- [x] Update `tests/test_backend.py`.
  - Prompt-specified dataset results in unchanged prompt.
  - Form fallback appends conditional instruction.
  - Default fallback appends conditional instruction.
- [x] Update `tests/test_jobs.py` or `tests/test_portal_flow.py`.
  - `create_job` with prompt dataset and blank form does not use default.
  - `create_job` with form dataset stores that dataset and backend prompt remains conditional.
  - `create_job` with neither uses default dataset.

### 3. Backend Runtime Defaults (Issue #6)

- [x] Add settings in `hep_data_web/settings/base.py`.
  - `HEP_DATA_LLM_MODEL = env("HEP_DATA_LLM_MODEL", "gpt-54-mini")`
  - `HEP_DATA_LLM_REPAIR_CYCLES = int(env("HEP_DATA_LLM_REPAIR_CYCLES", "10"))`
  - If the backend CLI names the option differently after inspection, use the actual CLI flags in the command helper.
- [x] Add adapter helpers in `portal.backend`.
  - `backend_model_cli_value() -> str`
  - `backend_repair_cycles() -> int`
  - Keep validation simple: model non-empty; repair cycles positive integer.
- [x] Update `portal.services._backend_command_for_job`.
  - Add model flag with value from settings.
  - Add repair/retry/cycles flag with value from settings.
  - Confirm flag names against `hep-data-llm` before implementation. If unknown, inspect the installed CLI with `uv run python -m hep_data_llm.cli plot --help`.
- [x] Update `.env.example`.
  - Document `HEP_DATA_LLM_MODEL=gpt-54-mini`.
  - Document `HEP_DATA_LLM_REPAIR_CYCLES=10`.
- [x] Update `tests/test_settings.py`.
  - Verify settings expose defaults and env overrides.
- [x] Update `tests/test_jobs.py`.
  - `_backend_command_for_job` contains the configured model and repair cycle options.

### 4. Per-profile Docker Image Configuration (Issue #10)

- [x] Replace global-only image selection in `portal.services._backend_command_for_job`.
  - Current code reads `settings.HEP_DATA_LLM_DOCKER_IMAGE`.
  - Move selection into `portal.backend.docker_image_for_profile(profile)`.
- [x] Add settings in `hep_data_web/settings/base.py`.
  - `HEP_DATA_LLM_SERVICEX_AWKWARD_DOCKER_IMAGE`
  - `HEP_DATA_LLM_RDF_DOCKER_IMAGE`
  - `HEP_DATA_LLM_DOCKER_IMAGE_GLOBAL_FALLBACK` if keeping legacy global override.
  - Consider leaving `HEP_DATA_LLM_DOCKER_IMAGE` as a backwards-compatible alias, but document that it is global fallback only.
- [x] Add tests in `tests/test_backend.py`.
  - ServiceX + Awkward profile returns only ServiceX image override.
  - RDF profile returns only RDF image override.
  - No override returns empty string or `None`, so no `--docker-image` flag is passed.
  - Legacy global fallback applies only when explicitly configured and no profile-specific override exists.
- [x] Update `tests/test_jobs.py`.
  - Backend command includes RDF image when job profile is `rdf`.
  - Backend command includes ServiceX image when profile is `servicex_awkward`.
  - Backend command omits `--docker-image` when selected profile has no override.
- [x] Update `.env.example`, `README.md`, and `docker-compose.yml`.
  - Remove or de-emphasize global `HEP_DATA_LLM_DOCKER_IMAGE`.
  - Add profile-specific variables to both web and worker environments.

### 5. Worker Crash and Restart Recovery (Issues #3 and #4)

- [x] Add a reusable failure message constant in `portal.services`.
  - Suggested text: `This job failed because the worker stopped unexpectedly before it finished. The exact cause is unknown.`
- [x] Add `mark_stale_running_jobs_failed()` in `portal.services`.
  - Filter `Job.objects.filter(status=JobStatus.RUNNING)`.
  - Mark each as `FAILED`, set `completed_at`, set `runtime` if `started_at` exists, clear `queue_position`, set the crash recovery failure message.
  - Call `refresh_queue_positions()` once after updates.
  - Return the number of recovered jobs for logging/tests.
- [x] Call startup recovery from `portal.management.commands.run_worker.Command.handle`.
  - Execute once before entering the polling loop.
  - Write a concise stdout line if any jobs were recovered.
  - Do not claim or rerun recovered jobs.
- [x] Strengthen `portal.services.process_job`.
  - Current catchable exceptions already call `mark_job_failed(job, str(exc))`.
  - Ensure `refresh_queue_positions()` runs in every terminal path.
  - Consider adding a catch around artifact recording in `mark_job_completed` if artifact persistence can fail after backend success. If it fails, mark failed with a plain message.
- [x] Add `tests/test_worker.py` startup recovery tests.
  - Running job becomes failed on `mark_stale_running_jobs_failed`.
  - Failure message matches the crash recovery message.
  - Queue positions exclude the recovered failed job.
  - A queued job remains queued and becomes position 1 after recovery.
- [x] Add `run_worker` command test.
  - Create a running job.
  - Patch `claim_and_process_next_job` to return `None`.
  - Call `run_worker --once`.
  - Assert stale running job was failed and not processed.
- [x] Keep clone/edit/resubmit behavior unchanged.
  - Existing `/jobs/<id>/clone/` is the supported recovery path.

### 6. Live Job Status Updates (Issue #5)

- [x] Create `templates/portal/_job_detail_panel.html`.
  - Move the main job state region from `job_detail.html` into the include.
  - Include status badge, queue position, timestamps, failure message, metadata, image previews, report download link, generated code, and artifacts list.
  - Keep user-visible behavior equivalent for full page render.
- [x] Update `templates/portal/job_detail.html`.
  - Render the include inside a wrapper, for example `<section id="job-detail-panel">`.
  - If job is queued or running, add polling attributes or a small script.
  - Poll only while `job.status` is `queued` or `running`.
- [x] Add `portal.views.job_detail_partial`.
  - Use `_job_or_404` for permission checks.
  - Recompute artifacts and timestamps with the same helper used by full `job_detail`.
  - Return the include template.
  - Add a `Cache-Control: no-store` header if convenient.
- [x] Refactor duplicated job-detail context into helper in `portal.views`.
  - Suggested helper: `_job_detail_context(request, job)`.
  - Use it from both full and partial views.
- [x] Add route in `portal/urls.py`.
  - Suggested path: `jobs/<uuid:submission_id>/status/`, name `job-detail-status`.
- [x] Add polling implementation.
  - HTMX option: add the HTMX script in `base.html`; set `hx-get`, `hx-trigger="load delay:2s"`, `hx-swap="outerHTML"` on a wrapper that re-renders itself while active.
  - Vanilla option: use `fetch` every `JOB_POLL_INTERVAL_SECONDS` and replace `#job-detail-panel` until a `data-terminal="true"` attribute appears.
  - Keep the implementation simple and testable by checking rendered attributes.
- [x] Add `tests/test_portal_flow.py` permission tests.
  - Owner can GET partial endpoint.
  - Other user gets 404 for partial endpoint.
  - Partial includes queued/running/completed/failed state text.
- [x] Add result update test.
  - Completed job with artifact returns download link and generated code in partial response.

### 7. Localized Timestamp Display (Issue #1)

- [x] Add a template helper pattern for timestamps.
  - Minimal approach: in templates, render:
    - `<time class="js-local-time" datetime="{{ value|date:'c' }}">UTC fallback text</time>`
    - Include visible fallback with `UTC`.
  - Avoid introducing a custom Django template tag unless duplication becomes hard to maintain.
- [x] Update `portal.views`.
  - Stop converting timestamps with `timezone.localtime` for user-facing display contexts where browser localization is expected.
  - Pass timezone-aware UTC datetimes or ISO strings.
  - Keep server fallback text explicit as UTC.
- [x] Update `templates/base.html`.
  - Add JavaScript that finds `.js-local-time`, parses `datetime`, formats with `Intl.DateTimeFormat`, and appends a timezone label from `Intl.DateTimeFormat().resolvedOptions().timeZone` or `timeZoneName: "short"`.
  - Leave fallback text untouched if parsing fails or JavaScript is disabled.
- [x] Update `templates/portal/job_detail.html` and `_job_detail_panel.html`.
  - Apply timestamp markup to submitted, started, and completed times.
- [x] Update `templates/portal/home.html` if history displays timestamps.
  - Current history table does not show submitted time; add it only if useful and covered by tests, otherwise no change needed there.
- [x] Add tests.
  - `tests/test_portal_flow.py`: job detail response contains `<time` and `datetime=`.
  - Assert fallback includes `UTC`.
  - Do not try to test browser timezone rendering in Django unit tests.

### 8. Example Prompt Presentation (Issue #7)

- [x] Update `templates/portal/home.html`.
  - Constrain example button text with Bootstrap/utilities and a small custom class if needed.
  - Preserve `data-example-prompt="{{ example.prompt|escape }}"`.
  - Add `title="{{ example.prompt|escape }}"` or an accessible details/summary area so the full prompt is available.
  - If using truncation, add visually clear text such as `View full prompt` with a collapsed details element or Bootstrap collapse.
- [x] Add CSS in `templates/base.html` or `home.html`.
  - Keep it minimal and theme-consistent.
  - Suggested class: `.example-prompt-text { display: -webkit-box; -webkit-line-clamp: 3; -webkit-box-orient: vertical; overflow: hidden; }`
  - Also set `overflow-wrap: anywhere;` for dataset-like strings.
- [x] Preserve click behavior.
  - Clicking the example button must still populate `#prompt` with the full prompt.
  - If the full prompt affordance is nested, ensure it does not break selection.
- [x] Update `tests/test_home_ui.py`.
  - Long prompt response contains the full prompt in `data-example-prompt`.
  - Long prompt response contains truncation/accessibility attributes or full prompt affordance.
  - Existing clickable example behavior remains represented in rendered JavaScript/data attributes.

### 9. Continuous Integration and Release Automation (Issue #2)

- [x] Add `.github/workflows/ci.yml`.
  - Trigger on pull requests and pushes to `main`.
  - Use `actions/checkout`.
  - Install `uv`.
  - Set up Python 3.12.
  - Run `uv sync --extra dev --frozen`.
  - Run `uv run pytest`.
  - Run `uv run ruff check .`.
  - Run `uv run ruff format --check .`.
- [x] Add `.github/workflows/release.yml`.
  - Trigger manually with `workflow_dispatch`, and optionally on published GitHub releases.
  - Build multi-arch Docker image for `linux/amd64` and `linux/arm64`.
  - Use Docker Buildx.
  - Authenticate with registry using GitHub Actions secrets.
  - Push only on the release trigger, not every branch push.
- [x] Document required secrets in `README.md` or `docs/azure-deployment.md`.
  - Registry server/username/password or token.
  - Image namespace/name.
  - Any Azure publish credentials if used later.
- [x] Add a CI status note to `README.md`.
  - Keep it concise.
- [x] Validate locally before committing.
  - Run `uv run pytest`.
  - Run `uv run ruff check .`.
  - Run `uv run ruff format --check .`.

### 10. Azure Deployment Scripts and Instructions (Issue #9)

- [x] Create `docs/azure-deployment.md`.
  - State prerequisite: operator is already logged in with `az login`.
  - List required Azure CLI version assumptions if known.
  - Explain first-time setup variables.
  - Explain certificate requirements, expected local certificate path, and where the certificate is registered.
  - Explain Docker registry auth and token handling without committing tokens.
  - Explain admin bootstrap: create Django superuser or approved admin profile after first deploy.
- [x] Create `scripts/azure/create-resources.ps1`.
  - Parameters should include resource group, location, app name prefix, container registry/image, database names, certificate path, and secrets source.
  - Create persistent database resources separately from ephemeral app resources.
  - Create storage or volumes needed for media/artifacts if used by the selected Azure service.
  - Configure app and worker environment variables.
  - Do not embed secrets; read them from environment variables or prompt securely.
- [x] Create `scripts/azure/delete-app-resources.ps1`.
  - Delete only ephemeral app/container/service resources.
  - Preserve database and persistent storage.
  - Make this the normal teardown command.
- [x] Create `scripts/azure/delete-persistent-data.ps1`.
  - Use explicit destructive naming and confirmation prompt.
  - Delete database and persistent storage only when explicitly invoked.
- [x] Update `.env.example` if Azure-specific runtime variables are introduced.
- [x] Add docs for private Docker image pulls.
  - Include token/credential setup through Azure or registry mechanisms.
  - Do not commit tokens or real credentials.
- [x] Manual verification checklist in docs.
  - Create resources from scratch.
  - Deploy web and worker.
  - Confirm login/approval/job metadata persists after app resource teardown/recreate.
  - Confirm destructive data deletion is separate.

### 11. Privacy and Permission Boundaries

- [x] For every new view or partial endpoint, use existing `_job_or_404(request, submission_id)` or equivalent owner/admin check.
- [x] Do not expose artifact paths for other users in live status responses.
- [x] Do not put prompts, generated code, or artifact metadata into CI logs or deployment scripts.
- [x] Add regression tests for the live partial endpoint.
  - Owner allowed.
  - Other regular user receives 404.
  - Staff/admin behavior should match existing full job detail behavior.
- [x] Verify admin-only docs/scripts do not commit secrets.

## Test Plan

### Focused unit tests

- `tests/test_backend.py`
  - Dataset prompt detection and conditional fallback prompt rendering.
  - Backend model and repair-cycle adapter helpers.
  - Per-profile Docker image selection.
- `tests/test_settings.py`
  - New environment defaults and overrides.
- `tests/test_jobs.py`
  - Job creation dataset paths.
  - Backend command includes model/repair cycles/profile image only when expected.
- `tests/test_worker.py`
  - Stale running jobs marked failed on startup recovery.
  - Catchable worker exceptions persist terminal failure state.
  - Queue counts and positions exclude recovered failed jobs.

### Integration and view tests

- `tests/test_auth.py`
  - Pending-to-approved refresh allows app access without logout.
  - Rejected refresh remains blocked.
- `tests/test_portal_flow.py`
  - Live status partial owner permission.
  - Live status partial other-user 404.
  - Terminal completed/failed states render in partial response.
  - Job detail contains machine-readable UTC timestamp markup.
- `tests/test_home_ui.py`
  - Long example prompt stays represented with truncation/accessibility affordance.
  - Full example prompt still exists in `data-example-prompt`.

### CI verification

- `uv run pytest`
- `uv run ruff check .`
- `uv run ruff format --check .`
- GitHub Actions PR and main branch checks run the same commands.

### Manual deployment verification

- Azure create script provisions resources for a logged-in Azure CLI user.
- Normal delete script removes app resources but preserves database/storage.
- Recreate app resources and confirm users, approvals, jobs, and metadata remain.
- Destructive persistent-data delete path requires explicit separate invocation.
- Private Docker image pull works with documented token/registry setup.
- Certificate is loaded from the documented location and registered in the documented Azure resource.

## Suggested Implementation Order

1. Approval refresh (#11), because it is small and isolated.
2. Dataset semantics (#8), backend runtime defaults (#6), and per-profile image config (#10), because they share the backend adapter and command construction.
3. Worker crash/restart recovery (#3/#4), because it touches queue correctness.
4. Live job status (#5) and timestamp localization (#1), because both touch the job detail template and should avoid duplicate template churn.
5. Example prompt presentation (#7), because it is a contained UI fix.
6. CI workflow (#2), because it should run all accumulated tests.
7. Azure scripts/docs (#9), because it is operationally larger and should come after runtime variables stabilize.

## Assumptions

- The default backend CLI model flag and repair-cycle flag must be confirmed against the installed `hep-data-llm` CLI before implementation.
- The existing `Job.resolved_dataset` field is sufficient if `result_metadata["dataset_source"]` is used for optional diagnostics; avoid a migration unless the implementation needs queryable dataset-source semantics.
- Single-worker semantics remain in scope; no distributed worker leases or heartbeats are required for this follow-up.
- HTMX is acceptable if the implementation keeps it limited to partial polling. If not, a small vanilla JavaScript polling loop is acceptable.
- Azure resource choices may vary by operator preference, but scripts must preserve the separation between ephemeral app resources and persistent data resources.
