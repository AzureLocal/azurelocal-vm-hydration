# Automation

Documents every GitHub Actions workflow in this repository.

---

## Workflow Summary

| File | Name | Trigger | Purpose |
|------|------|---------|---------|
| `add-to-project.yml` | Add to Project | Issues/PRs opened or labeled | Adds VM Hydration issues/PRs to the shared AzureLocal project and sets custom fields |
| `deploy-docs.yml` | Deploy Documentation | Push to `main` touching `docs/**` or `mkdocs.yml` | Builds MkDocs site and deploys to GitHub Pages |
| `validate-repo-structure.yml` | Validate Repo Structure | Pull requests to `main` | Checks required root files and directories exist before merge |
| `release-please.yml` | Release Please | Push to `main` | Automates CHANGELOG and releases |

---

## add-to-project.yml

**Trigger:** `issues` (opened, labeled) and `pull_request` (opened, labeled)  
**Permissions required:** `ADD_TO_PROJECT_PAT` — classic PAT with `project` scope

**What it does:**

1. Adds new VM Hydration issues and PRs to `AzureLocal/projects/3`
2. Sets the `ID` field to `HYDRATION-{number}`
3. Maps `solution/hydration` to the Hydration solution option
4. Maps `priority/*` labels to the shared Priority field
5. Maps `type/*` labels to the shared Category field

This is the VM Hydration copy of the canonical AzureLocal project integration workflow.

---

## deploy-docs.yml

**Trigger:** Push to `main` touching `docs/**` or `mkdocs.yml`  
**Permissions:** `contents: read`, `pages: write`, `id-token: write`  
**Concurrency group:** `pages` (cancel-in-progress: false)

Two-job pipeline:

**build:**
1. Sets up Python 3.12
2. Installs `mkdocs-material`
3. `mkdocs build --strict` — fails on any warning
4. Uploads `site/` as a pages artifact

**deploy:**
1. Uses `actions/deploy-pages@v4` to publish to GitHub Pages

---

## validate-repo-structure.yml

**Trigger:** Pull requests to `main`  
**Purpose:** Catch missing required files before merge.

Validation steps:

1. Checks required root files: `README.md`, `CONTRIBUTING.md`, `LICENSE`, `CHANGELOG.md`, `.gitignore`
2. Checks required directories: `docs/`, `.github/`
3. Reports missing items as errors with `::error::` annotations
4. Exits with code 1 if any check fails

---

## release-please.yml

**Trigger:** Push to `main`  
**Permissions:** `contents: write`, `pull-requests: write`

Uses `googleapis/release-please-action@v4` with explicit config:
- `config-file: release-please-config.json`
- `manifest-file: .release-please-manifest.json`

Both files must exist at the repo root. The workflow maintains an automated release PR that updates `CHANGELOG.md` and bumps the version. Merging it creates the GitHub release and tag.
