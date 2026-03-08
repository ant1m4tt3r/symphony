# Local Development Guide

## Push Protection Toggle

This repository includes a pre-push hook that blocks direct pushes to `main` by default. This enforces the production merge policy: all changes must go through a PR with human review before merging.

### Local Development Toggle

For local development convenience, you can disable the push protection by setting an environment variable:

```bash
export SYMPHONY_ALLOW_LOCAL_DEV=1
```

With this toggle enabled, you can push directly to `main` for local testing.

### Important: Production Policy

**This toggle is intended for local development only.**

Production policy remains unchanged:
- All changes must go through a PR flow
- All merges require manual human review and approval
- Never enable this toggle in CI/CD or production environments

### Rationale

This protection ensures:
1. All code changes are reviewed before landing
2. Merge history is preserved through PR merges
3. CI/CD pipelines run on PR branches before merge
4. Audit trail of changes via PR descriptions and comments
