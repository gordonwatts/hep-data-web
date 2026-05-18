---
name: implement-from-spec
description: Implement software work from an existing specification, roadmap, design document, or implementation checklist. Use when Codex should plan from a spec, create or revise a checklist, continue from unchecked items, execute work in small verified increments, and keep tests and documentation aligned across sessions or with limited prior context.
---

# Implement From Spec

Use written repository artifacts as the source of truth for planning and execution.

## Choose the mode

Infer the mode from the user request:

- **Plan from spec** when the user asks for an implementation plan, roadmap, checklist, or step-by-step process from an existing spec.
- **Execute from plan** when the user asks to implement, continue, resume, or work through an existing checklist or plan.

If both are needed, create or repair the plan first, then execute from it.

## Shared starting workflow

1. Read the governing documents before acting:
   - the requested spec or design document
   - the implementation plan or checklist, if present
   - `AGENTS.md`, if present
   - directly relevant README or architecture notes
2. Inspect the current repository state:
   - identify the stack, conventions, and nearby implementation patterns
   - confirm what already exists
   - locate the next unchecked item when a checklist exists
3. Prefer repository truth over memory or prior conversation when written artifacts exist.
4. Identify unresolved decisions only after inspection.
   - Ask when a missing choice materially affects the outcome.
   - Recommend a default and explain the consequence briefly.
   - Do not ask for facts that can be discovered from the repository.

## Plan from spec

When creating or revising an implementation plan:

1. Preserve the product intent and explicit decisions from the spec.
2. Split the work into small, ordered, checkable steps.
3. Keep each step narrow enough for a weaker model to complete safely in one focused pass.
4. Include the minimum interfaces, assumptions, and tests needed to make execution decision-complete.
5. Use checklist form when the plan is intended to drive future implementation.
6. If the repo already has a plan, revise it instead of creating a competing version unless the user asks otherwise.

Use [references/checklist-template.md](references/checklist-template.md) when a lightweight checklist skeleton is useful.

## Execute from plan

When implementing from an existing plan:

1. Resume from the next unchecked item unless there is a clear blocker.
2. Work in dependency order.
3. Prefer one narrow checklist item, or one tightly related group, at a time.
4. Implement the behavior, update or add tests, and run the strongest practical verification available for that scope.
5. Mark checklist items complete only after the work is actually verified.
6. Keep code, tests, docs, and checklist status aligned.
7. If implementation reveals the plan is wrong or incomplete, update the plan explicitly rather than drifting silently.

## Checklist quality bar

A good checklist item should:

- describe one concrete outcome
- be short enough to implement safely in one focused pass
- have an obvious verification method
- avoid combining unrelated concerns

Prefer:

- `Add Job model with queued/running/completed/failed states`
- `Add queue-limit validation for new submissions`
- `Add tests for user isolation on job detail pages`

Avoid:

- `Build backend`
- `Implement auth`
- `Finish UI`

## Verification expectations

Use the strongest practical verification available:

- targeted unit tests for local behavior
- integration tests for workflows and boundaries
- formatting and lint checks when configured
- manual verification only when automated checks are insufficient

If a verification step cannot be run:

- state why
- say what was verified instead
- do not imply full confidence without evidence

## Execution rules

- Treat the spec as product intent and the checklist as execution state.
- Do not collapse large work into broad vague changes; split until the work is safe to execute.
- Do not mark work complete based only on code written.
- Do not bypass agreed architecture or repository guidance without calling out why.
- Prefer incremental progress over speculative large refactors.
- If the user says “continue,” resume from the next unchecked item unless another next step is clearly safer.

## Stopping points

Prefer stopping after:

- a checklist item is implemented
- tests are green
- docs and checklist state are updated
- the next step is clear

Avoid stopping:

- halfway through a migration
- after code changes but before tests
- with checklist state out of sync with reality

## Status reporting

At each meaningful stopping point, report:

- what changed
- which checklist items were completed
- what was verified
- what remains next
- assumptions, deviations, or open risks
