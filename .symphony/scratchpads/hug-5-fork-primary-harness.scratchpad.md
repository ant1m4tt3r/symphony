# HUG-5 Scratchpad

## Summary

Make this fork the primary Symphony harness by ensuring agent contract discovery,
reproducible local setup/build/start, and current fork-scoped docs/env guidance.

## Reproduction signal

- `test -f WORKFLOW.md` at repo root reports file missing.
- `docs/symphony.md` includes host-specific absolute path text.
- `scripts/symphony/test-guards.sh` fails in harnessed shells when
  `SYMPHONY_REAL_GIT`/`SYMPHONY_REAL_GH` are pre-set.

## Plan

- [x] Add repository-root `WORKFLOW.md` for spawned issue workspace agents.
- [x] Refresh harness docs for reproducible setup/build/start and env bootstrap.
- [x] Align top-level README pointer to fork harness docs.
- [x] Harden guard regression tests so missing-binary assertions are env-stable.
- [x] Validate guard behavior and workflow generation path with scripts.

## Validation

- [x] `./scripts/symphony/test-guards.sh`
  - Result: `All guard regression tests passed.`
- [x] `SYMPHONY_ENV_FILE=<temp-env> SYMPHONY_VALIDATE_ONLY=1 ./scripts/symphony/start.sh`
  - Result: `Workflow config valid` and
    `Validation complete: .../.symphony/WORKFLOW.generated.md`
