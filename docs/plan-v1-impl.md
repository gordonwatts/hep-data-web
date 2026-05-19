# HEP Data LLM Web Frontend V1 Implementation Plan

## Summary

Build a small Django monolith that wraps the existing `hep-data-llm` workflow with:

- GitHub OAuth login and manual user approval
- A simple prompt-driven UI with backend profile selection
- Persistent queued jobs executed asynchronously by one worker
- Per-user history and result pages
- Admin pages for approvals, queue inspection, cancellation, and deletion
- Persistent PostgreSQL storage plus filesystem-backed artifacts
- Docker-first local deployment

The work is intentionally split into small, checkable steps so it can be implemented safely by a simpler model.

## Chosen Defaults

- **Framework:** Django monolith
- **UI:** Django templates + light HTMX
- **Visual system:** Bootstrap 5.3 with a custom “Quiet Scientific Portal” theme
- **Database:** PostgreSQL
- **Queue model:** Database-backed queue with one worker process
- **Artifact storage:** Persistent filesystem volume
- **Admin UX:** Custom lightweight admin pages
- **Email:** Console backend in development, SMTP in production
- **Deployment:** Docker Compose for app + PostgreSQL
- **Backend integration:** Pin a specific `hep-data-llm` version; do not track backend HEAD automatically

## Public Interfaces / Core Concepts

### Main user-facing pages

- `/` — prompt submission page, examples, and current user history
- `/jobs/<id>/` — job result page
- `/jobs/<id>/clone/` — clone/edit/resubmit flow
- `/admin/users/` — pending user approvals
- `/admin/jobs/` — global job and queue inspection

### Core data models

- `UserProfile`
  - linked Django user
  - approval status
  - role (`user`, `admin`)
- `Job`
  - owner
  - original prompt
  - resolved dataset
  - backend profile
  - status (`queued`, `running`, `completed`, `failed`, `cancelled`)
  - queue metadata
  - timestamps
  - runtime
  - failure message
  - artifact references
- `JobArtifact`
  - job
  - artifact kind
  - path
  - whether it is the canonical downloadable artifact

### Operational processes

- Web app process
- Worker process that:
  - claims the next queued job
  - runs exactly one job at a time
  - updates job state
  - stores artifacts
  - sends terminal-state email

## Implementation Checklist

### 1. Project foundation

- [x] Create a new Django project and one primary application module.
- [x] Add dependency management with `pyproject.toml`.
- [x] Add local environment instructions using `uv`.
- [x] Add `.env.example` with all required environment variables.
- [x] Add baseline formatting, linting, and test configuration.
- [x] Add initial Dockerfile and `docker-compose.yml` for app + PostgreSQL.

### 2. Configuration and environments

- [x] Split Django settings into development-friendly defaults driven by environment variables.
- [x] Configure PostgreSQL from environment variables.
- [x] Configure static files, media files, and persistent artifact storage paths.
- [x] Configure development email backend to console output.
- [x] Configure production email backend through SMTP environment variables.
- [x] Add settings for GitHub OAuth credentials.
- [x] Add settings for backend package version and runtime-related limits.

### 3. Authentication and approval flow

- [ ] Add GitHub OAuth authentication.
- [ ] Create `UserProfile` with role and approval state.
- [ ] On first login, create a pending profile instead of granting access.
- [ ] Block pending and rejected users from normal app pages.
- [ ] Send admin notification email when a new user becomes pending.
- [ ] Build admin approval list page.
- [ ] Add approve and reject actions.
- [ ] Send user notification email after approval or rejection.
- [ ] Add tests for login, pending state, approval, rejection, and permission boundaries.

### 4. Backend integration scaffolding

- [x] Pin one explicit `hep-data-llm` version in dependencies.
- [x] Add a small integration-layer module that calls backend functionality from one place.
- [x] Add a helper to load example questions from the backend package.
- [x] Add a helper to obtain or define the default dataset from backend examples.
- [x] Add support for the backend profile choices exposed in V1:
  - [x] ServiceX + Awkward
  - [x] RDF
- [x] Add unit tests around the integration layer using mocks or fakes rather than running real analysis jobs.

### 5. Job and artifact persistence

- [x] Create the `Job` model.
- [x] Create the `JobArtifact` model.
- [x] Add migrations.
- [x] Add job creation logic that:
  - [x] records the user prompt
  - [x] injects the default dataset when none is supplied
  - [x] records the selected backend profile
  - [x] rejects submission when the global queue already has 20 active queued/running jobs
- [x] Add helper logic for queue depth and queue position.
- [x] Add artifact path conventions under a persistent media/artifact directory.
- [x] Add tests for job creation, default dataset injection, queue limit enforcement, and artifact metadata.

### 6. Worker and execution flow

- [x] Add a worker command/process separate from HTTP request handling.
- [x] Implement atomic claiming of the next queued job.
- [x] Ensure only one job is processed at a time.
- [x] Transition job states through queued → running → completed/failed.
- [x] Capture runtime, completion timestamp, failure message, generated code, and artifact references.
- [x] Preserve backend container-per-job execution behavior where feasible.
- [ ] Add cancellation handling before execution begins and during safe checkpoints.
- [ ] Send completion/failure emails only at terminal states.
- [ ] Add tests for:
  - [x] queued job claim order
  - [x] successful completion
  - [x] failed execution
  - [ ] cancellation
  - [ ] email trigger behavior
  - [ ] worker restart behavior with persisted state

### 7. User-facing UI

- [x] Establish the shared visual theme before building individual pages:
  - [x] Use Bootstrap 5.3 as the base component framework.
  - [x] Define a small custom theme with navy primary color, warm neutral page background, white content surfaces, slate text, pale borders, and one restrained accent color.
  - [x] Prefer Bootstrap components over one-off custom CSS.
  - [x] Keep layouts spacious, readable, and beginner-friendly rather than dashboard-dense.
- [x] Build the main page with:
  - [x] prompt input
  - [x] backend profile dropdown
  - [x] clickable example prompts
  - [x] show three random example prompts per page load
  - [x] current user history table
- [x] Add queue-full messaging with friendly wording.
- [ ] Add HTMX-driven partial refresh for queue position/status where useful.
- [x] Build the result page with:
  - [x] inline plot preview(s)
  - [x] inline generated code with syntax highlighting
  - [x] metadata
  - [x] error state
  - [x] download links
- [x] Add clone/edit/resubmit flow instead of exact rerun.
- [x] Ensure users only see their own jobs and artifacts.
- [x] Keep page structure consistent across the app:
  - [x] simple top navigation
  - [x] centered content area
  - [x] card-based major sections
  - [x] one clear primary action per page
  - [x] compact readable tables
  - [x] status shown with text plus badges, not color alone
  - [x] dark code-display panel for generated code
- [x] Add UI tests for submission, history visibility, result rendering, clone flow, and authorization.

### 8. Admin UI

- [ ] Build admin user approval page.
- [ ] Build admin global job/queue page.
- [ ] Add admin-only job inspection.
- [ ] Add admin cancel action.
- [ ] Add admin delete action.
- [ ] Confirm destructive admin actions require explicit form submissions.
- [ ] Add tests for admin permissions and admin-only actions.

### 9. Docker and local operations

- [x] Complete Dockerfile for the Django app.
- [x] Add `docker-compose.yml` services for:
  - [x] web
  - [x] worker
  - [x] postgres
- [x] Add named volumes for:
  - [x] PostgreSQL data
  - [x] persisted artifacts
- [ ] Add startup commands for migrations and static collection where needed.
- [ ] Document local startup:
  - [ ] create `.env`
  - [ ] run `docker compose up`
  - [ ] create admin user
  - [ ] log in and approve users
- [ ] Verify data survives container restart.
- [ ] Verify artifacts survive container restart.

### 10. Documentation and developer guidance

- [ ] Keep `AGENTS.md` short and operational.
- [ ] Add README or docs sections for:
  - [ ] local setup
  - [ ] environment variables
  - [ ] test commands
  - [x] worker operation
  - [x] Docker Compose usage

### 11. Final verification pass

- [x] Run formatting, linting, and tests.
- [ ] Run migrations from a clean database.
- [x] Bring the stack up with Docker Compose.
- [ ] Manually verify:
  - [ ] first-login pending user flow
  - [ ] admin approval flow
  - [ ] prompt submission
  - [ ] queue position updates
  - [ ] result page rendering
  - [ ] email delivery in development mode
  - [ ] admin cancellation/deletion
  - [ ] restart persistence for jobs and artifacts
- [ ] Confirm no HTTP request path directly executes analysis work.
- [ ] Confirm ordinary users cannot access other users’ jobs or artifacts.

## Test Plan

### Unit tests

- [ ] User approval state transitions
- [x] Queue limit logic
- [x] Queue position logic
- [x] Default dataset injection
- [x] Backend profile validation
- [ ] Worker state transitions
- [x] Artifact metadata handling
- [ ] Permission helpers

### Integration tests

- [ ] OAuth callback flow with mocked provider
- [ ] Job submission → worker processing → result availability
- [ ] Failure path preserving generated code and error message
- [ ] Email notifications for terminal states
- [ ] User isolation
- [ ] Admin approval/cancel/delete flows

### Manual acceptance scenarios

- [ ] New user logs in and is held for approval
- [ ] Approved user submits prompt without dataset and gets default dataset behavior
- [ ] Queue fills to limit and rejects the 21st active request
- [ ] User disconnects and later returns to see completed history
- [ ] Failed job remains visible with code and failure text
- [ ] Admin can inspect all jobs but regular user cannot

## Assumptions

- V1 targets a single-node deployment and does not need distributed workers.
- A single worker process is acceptable for the initial workload.
- Filesystem-backed artifacts are sufficient for the expected storage size.
- GitHub OAuth is acceptable even though future auth may move to CERN SSO or OIDC.
- Example prompts and default dataset values should be reused from the backend package rather than duplicated manually when practical.
- Exact reproducibility is out of scope; clone/edit/resubmit is the supported reuse behavior.
- The V1 visual style should prioritize calm consistency and implementation simplicity over custom branding or a highly interactive frontend.
