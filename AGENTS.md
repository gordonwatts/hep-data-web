# AGENTS.md

## Working Agreement

- Keep changes small, explicit, and easy to review.
- Prefer the simplest implementation that satisfies the V1 spec.
- Preserve user privacy boundaries in every query, view, and template.
- Do not execute analysis jobs inside HTTP request handlers; use the worker flow.
- Keep backend integration behind a small adapter layer so `hep-data-llm` details do not leak through the app.
- Do not commit secrets, tokens, or real `.env` files.

## Python Environment

- Use `uv` for local Python environment management.
- Create the environment with `uv sync` once `pyproject.toml` exists.
- Run commands through `uv run ...` so the correct environment is always used.

## Testing

- Add tests with each behavior change.
- Prefer focused unit tests plus a small number of integration tests for end-to-end flows.
- Before considering work complete, run:
  - `uv run pytest`
  - the configured formatter check
  - the configured linter
- When changing permissions, queueing, or worker behavior, add regression tests for the failure case as well as the happy path.

## Implementation Practices

- Keep queue state transitions explicit and persistent.
- Use environment variables for configuration; document new variables in `.env.example`.
- Prefer server-rendered pages and light HTMX over unnecessary frontend complexity.
- Reuse existing backend semantics instead of inventing new plotting behavior.
- Pin external dependency versions used for deployment-sensitive behavior.

## UI Style

- Use Bootstrap 5.3 components by default instead of inventing custom widgets.
- Follow the “Quiet Scientific Portal” theme:
  - navy primary color
  - warm neutral page background
  - white content cards
  - slate text
  - pale borders
  - one restrained accent color
- Keep pages spacious, calm, and beginner-friendly.
- Use a consistent page shape: simple top nav, centered content, cards for major sections, and one obvious primary action.
- Show status with words plus badges/icons; never rely on color alone.
- Render generated code in a dark monospace panel for readability.
