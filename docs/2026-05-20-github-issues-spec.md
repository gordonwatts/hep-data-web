# GitHub Issues Follow-up Specification

## Overview

This specification consolidates the current open GitHub issues for `gordonwatts/hep-data-web` into a single behavior-focused document.

It extends the V1 product specification in `docs/plan-v1-spec.md` and is intended to be the source for a later implementation plan.

Issue inventory captured on 2026-05-20:

| Issue | Title | Type |
| --- | --- | --- |
| #1 | Times should be in web-local time zone (and specified) | Bug |
| #2 | Add github CI | Enhancement |
| #3 | Don't re-run queries that crash | Bug |
| #4 | Make sure all crashes in the worker are properly marked | Bug |
| #5 | The /jobs/xxx page should auto update | Enhancement |
| #6 | Run with up to 10 cycles and default LLM of gpt-5.4-mini | Enhancement |
| #7 | Example prompts are too long and stretch way off the page | Bug |
| #8 | Dataset override should not be required... | Bug |
| #9 | Azure Deployment Scripts and Instructions | Enhancement |
| #10 | docker image should not override | Bug |
| #11 | "Acceptance" of a user should not require them to log out and log back in | Bug |

## Goals

The follow-up work should:

- Make queued and running jobs easier to monitor and recover from.
- Preserve prompt-driven dataset behavior without forcing users to understand backend details.
- Improve first-use and approval flows for new users.
- Make displayed timestamps clear, browser-local, and labeled.
- Improve frontend polish for long example prompts and live job pages.
- Add continuous integration and release automation.
- Prepare deployment documentation and scripts for Azure while preserving persistent data.
- Keep backend-specific configuration behind the adapter layer.

## Non-goals

This follow-up does not introduce:

- A new analysis backend.
- Notebook-like execution.
- Multi-worker scheduling.
- Public sharing of prompts, code, plots, or job history.
- Automatic rerun of crashed or abandoned analysis jobs.

## User Approval Refresh

Covers issue #11.

### Current Problem

After an admin approves a pending user, that user must log out and log back in before the application recognizes their approved state.

### Required Behavior

- A pending or rejected user status page must be refresh-safe.
- When the user refreshes the page after admin approval, the application must re-check the persisted approval state.
- If the persisted state is now approved, the user must be allowed into the normal app without logging out.
- If the persisted state is still pending or rejected, the page must continue to show the correct state.

### Acceptance Criteria

- A pending user can refresh the status page after approval and enter the application.
- No session logout/login cycle is required after approval.
- Rejected users remain blocked after refresh.
- Tests cover pending-to-approved refresh behavior and rejected refresh behavior.

## Dataset Selection Semantics

Covers issue #8.

### Current Problem

The current dataset handling can require a dataset override even though the intended workflow is natural-language driven.

### Required Behavior

Dataset resolution must follow this order:

1. If the prompt explicitly specifies a dataset, the backend should use the dataset described in the prompt.
2. If the user provides a separate dataset form value, the app should include that dataset instruction with the request.
3. If neither prompt nor form specifies a dataset, the app should inject the configured default dataset instruction.

The app should not blindly override a dataset named by the user in the prompt.

### Prompt Injection Requirement

When the dataset is not specified in the prompt but is known from form input or default configuration, the app should add clear instruction text to the backend request, such as:

```text
If this question does not specify a dataset, use <dataset>.
```

The exact wording may change, but it must preserve the distinction between a prompt-specified dataset and a fallback dataset.

### Acceptance Criteria

- Prompt-specified datasets are not overwritten by the app.
- Form-specified datasets are applied only as a fallback instruction.
- Default dataset is applied only when neither prompt nor form supplies one.
- Tests cover all three resolution paths.

## Backend Runtime Defaults

Covers issue #6.

### Required Behavior

- The default LLM for backend analysis jobs should be `gpt-5.4-mini` (called `gpt-54-mini` on the command line).
- Backend execution should allow up to 10 repair/retry cycles.
- These defaults should be configurable through environment variables.
- Defaults should be applied through the backend adapter layer rather than scattered through views or worker code.

### Acceptance Criteria

- New jobs use `gpt-5.4-mini` unless configuration overrides it.
- New jobs allow 10 repair/retry cycles unless configuration overrides it.
- Tests verify the adapter receives the configured model and retry/cycle count.
- `.env.example` documents the relevant variables.

## Per-profile Docker Image Configuration

Covers issue #10.

### Current Problem

There is a different Docker image associated with each backend profile, so one global Docker image override is insufficient and can send the wrong image for a selected profile.

### Required Behavior

- Docker image configuration must be profile-aware.
- The selected backend profile determines which Docker image override, if any, is passed to the backend.
- The app must not use one global override for all profiles unless that behavior is explicitly intended and named as such.
- Profile-to-image configuration must live in the backend adapter/configuration layer.

### Acceptance Criteria

- ServiceX + Awkward and RDF profiles can have distinct Docker image overrides.
- Selecting one profile does not pass another profile's Docker image.
- If no override is configured for a profile, the backend default for that profile is used.
- `.env.example` documents per-profile image variables.
- Tests cover image selection for each supported profile.

## Worker Crash and Restart Recovery

Covers issues #3 and #4.

### Current Problems

- Jobs can remain stuck in `running` forever if the worker crashes.
- On restart, the system must not automatically rerun jobs that were running when the process died.
- Users need a clear terminal state when a job dies unexpectedly.

### Required Behavior

- Worker startup must scan persisted jobs for stale `running` jobs owned by a previous worker lifetime.
- Stale running jobs must be moved to the existing terminal `failed` state.
- The failure message must explain that the job failed because the worker stopped or crashed for unknown reasons before completing the job.
- The job must remain visible in the user's history.
- The user must be able to clone/edit/resubmit the failed job, preserving the V1 no-exact-rerun semantics.
- Worker execution must catch unexpected exceptions and persist failure state before exiting whenever possible.
- Worker execution must avoid leaving a claimed job in `running` if an exception is catchable.

### State Semantics

The implementation should reuse the existing `failed` state rather than adding a new `crashed` state.

Crash/restart recovery failures must be distinguished by the normal failure message shown to users and admins. The message should be plain and direct, for example:

```text
This job failed because the worker stopped unexpectedly before it finished. The exact cause is unknown.
```

### Acceptance Criteria

- Restarting the worker marks stale running jobs as terminal failures.
- Stale running jobs are not re-executed automatically.
- Catchable worker exceptions persist a terminal job state.
- Queue counts and positions exclude these failed terminal jobs.
- Tests cover startup recovery, catchable worker exception handling, and no automatic rerun.

## Live Job Status Updates

Covers issue #5.

### Required Behavior

- The job detail page must update while a job is queued or running.
- Updates should include status, queue position where relevant, timestamps, failure state, generated results, and download links once available.
- The implementation should stay light and fit the existing server-rendered/HTMX direction.
- Polling should stop or become inert once the job reaches a terminal state.

### Acceptance Criteria

- A user can leave `/jobs/<id>/` open and see queued, running, completed, or failed state changes without manual refresh.
- Terminal results render into the page when available.
- Polling does not reveal jobs or artifacts owned by other users.
- Tests cover the partial update endpoint or view permissions.

## Localized Timestamp Display

Covers issue #1.

### Current Problem

Status pages show timestamps in an unknown timezone.

### Required Behavior

- User-facing timestamps must be displayed in the browser's local timezone.
- The timezone code or label must be displayed next to localized timestamps.
- Server-rendered markup should provide machine-readable UTC timestamps so frontend code can localize them reliably.
- The UI must not rely on color alone to communicate status or freshness.

### Acceptance Criteria

- Job timestamps render in the browser-local timezone.
- The displayed timestamp includes a timezone label.
- If JavaScript is unavailable, timestamps remain understandable, preferably as UTC with an explicit label.
- Tests cover the presence of machine-readable timestamp markup.

## Example Prompt Presentation

Covers issue #7.

### Current Problem

Long example prompts stretch the home page layout.

### Required Behavior

- Example prompts on the home page must be visually truncated or otherwise constrained so they do not break the page layout.
- Users must still be able to access the full prompt text before choosing it.
- Clicking an example should continue to populate the prompt input.
- A tooltip, expansion affordance, modal, or accessible detail view may be used for the full prompt.

### Acceptance Criteria

- Long example prompts stay within their content area on desktop and mobile.
- Full prompt text is available through click, focus, hover, or another accessible interaction.
- Example prompt selection still fills the prompt input accurately.
- UI tests cover long prompt rendering and selection.

## Continuous Integration and Release Automation

Covers issue #2.

### Required Behavior

- GitHub CI must run the full project test suite.
- CI must include the configured formatter check and linter.
- A release workflow must build Docker images and push them to the configured registry (for both amd64 and arm64)
- Release publishing must be opt-in through a release trigger rather than every branch push.
- Secrets required for registry login must be stored in GitHub Actions secrets.

### Acceptance Criteria

- Pull requests run tests, formatter check, and linter.
- Main branch pushes run the same checks.
- Release workflow builds the Docker image.
- Release workflow authenticates to the image registry without committing credentials.
- Documentation explains required repository secrets.

## Azure Deployment Scripts and Instructions

Covers issue #9.

### Required Behavior

The repository must include Azure deployment instructions and scripts that assume the operator is already logged in with the Azure CLI.

The Azure deployment workflow must include:

- Scripted creation of the required Azure resources from scratch.
- Scripted deletion of the deployed service resources.
- Persistent database storage so login, registration, approval, and job metadata are not lost across application teardown/redeploy.
- Private or authenticated Docker image pull support using Docker login/access token mechanisms.
- Clear operator instructions for first-time setup.
- Certificate requirements, expected certificate location, and where the certificate is registered.
- First-run instructions for creating or obtaining a superuser/admin account.

### Data Preservation Requirement

Deletion scripts must distinguish between ephemeral application resources and persistent data resources.

If a destructive delete path exists for persistent database resources, it must be explicit, separately named, and documented as destructive.

### Acceptance Criteria

- A logged-in Azure CLI user can run documented commands to create the deployment.
- A logged-in Azure CLI user can run documented commands to remove application resources.
- Database persistence survives app deletion/recreation unless the operator explicitly chooses a destructive path.
- Docker image pull authentication is documented and scripted without committing tokens.
- Instructions document certificate and admin bootstrap requirements.

## Privacy and Permissions

All follow-up work must preserve the V1 privacy model:

- Regular users can only see their own jobs, prompts, code, plots, artifacts, timestamps, and live status updates.
- Admin-only views must remain protected.
- Background worker state changes must not leak prompts or artifacts across users.
- CI, deployment scripts, and documentation must not commit secrets or real environment files.

## Verification Expectations

Before this follow-up work is considered complete, the implementation plan should include:

- Focused unit tests for configuration, adapter behavior, dataset fallback, crash recovery, and status transitions.
- Integration tests for user approval refresh, live job page updates, timestamp markup, and permission boundaries.
- UI tests for long example prompts and status/result page behavior.
- CI verification that runs tests, formatter check, and linter.
- Manual deployment verification for Azure scripts before documenting them as complete.
