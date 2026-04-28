# Repository Setup

Documents how this repository is configured. Use this as the reference when setting up a new repo or auditing existing settings.

---

## Branch Protection

**Protected branch:** `main`

| Setting | Value |
|---------|-------|
| Require pull request before merging | Yes |
| Required approvals | 1 |
| Dismiss stale reviews on new commits | Yes |
| Require status checks to pass | Yes |
| Require branches to be up to date | Yes |
| Restrict force pushes | Yes |
| Allow admins to bypass | Yes |

---

## Labels

Labels are defined in `azurelocal.github.io/.github/labels.yml` — that is the source of truth for all repos. Labels are applied when they change in the source repo or manually via `workflow_dispatch` on `sync-labels.yml` in `azurelocal.github.io`.

VM Hydration uses the shared `type/*`, `priority/*`, and `status/*` labels plus `solution/hydration` for hydration-specific work.

---

## Secrets

| Secret | Used By | Description |
|--------|---------|-------------|
| `ADD_TO_PROJECT_PAT` | `add-to-project.yml` | Classic PAT with `project` scope. Required for org project integration and field updates. |
| `GITHUB_TOKEN` | All other workflows | Built-in GitHub token. |

If `ADD_TO_PROJECT_PAT` is missing, the project integration workflow will not be able to add or update project items.

---

## Issue Intake

Issue intake is standardized with repo-local templates under `.github/ISSUE_TEMPLATE/`:

- `bug_report.md`
- `feature_request.md`
- `docs_issue.md`
- `config.yml`

---

## Project Board

VM Hydration participates in the shared org-level project board: [AzureLocal Projects #3](https://github.com/orgs/AzureLocal/projects/3).

| Setting | Value |
|---------|-------|
| Project | `AzureLocal/projects/3` |
| Project ID | `PVT_kwDOCxeiOM4BR2KZ` |
| Integration | `.github/workflows/add-to-project.yml` |
| Solution Label | `solution/hydration` |

### Custom Fields

| Field | Type | Usage |
|-------|------|-------|
| ID | Text | Auto-set to `HYDRATION-{issueNumber}` |
| Solution | Single Select | Set from `solution/hydration` label |
| Priority | Single Select | Set from `priority/*` labels |
| Category | Single Select | Set from `type/*` labels |

---

## Milestones

- `Planning`
- `Documentation Foundation`
- `v1.0`
- `Post-v1`

Issue grouping should be milestone-first, with labels and tracker issues used for classification and rollup.

---

## Issue Metadata Requirements

Every VM Hydration issue should have at minimum:

- one `type/*` label
- one `priority/*` label
- `solution/hydration`
- a milestone if it represents planned delivery work
- explicit dependency notes where sequencing matters

---

## CODEOWNERS

Defined in `.github/CODEOWNERS`. Review and update if team membership changes.

---

## GitHub Pages

| Setting | Value |
|---------|-------|
| Source | GitHub Actions (uses `actions/deploy-pages`) |
| Build tool | MkDocs Material |
| Deploy trigger | Push to `main` touching `docs/**` or `mkdocs.yml` |
| HTTPS enforced | Yes |

---

## Release Please Configuration

This repo uses an explicit `config-file` and `manifest-file` in `release-please.yml`, pointing to `release-please-config.json` and `.release-please-manifest.json` at the repo root. Both files must exist for the workflow to function.

---

## Replication Checklist

- [ ] Enable branch protection on `main` per settings above
- [ ] Add `.github/CODEOWNERS`
- [ ] Add `.github/PULL_REQUEST_TEMPLATE.md`
- [ ] Add `.github/ISSUE_TEMPLATE/` files for bug, feature, and docs intake
- [ ] Add `solution/hydration` label from the central label source
- [ ] Add `.github/workflows/add-to-project.yml` and confirm `HYDRATION-` ID prefix
- [ ] Add `ADD_TO_PROJECT_PAT`
- [ ] Copy `release-please.yml` and create `release-please-config.json` + `.release-please-manifest.json`
- [ ] Copy `deploy-docs.yml`
- [ ] Enable GitHub Pages (Settings → Pages → Source: GitHub Actions)
- [ ] Create milestones for `Planning`, `Documentation Foundation`, `v1.0`, and `Post-v1`
- [ ] Add issues to the shared project board and ensure fields are populated
