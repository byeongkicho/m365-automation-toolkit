# CLAUDE.md -- m365-automation-toolkit

> Project-level instructions for AI pair programming sessions in this repo.
> Loaded automatically by Claude Code at the start of every conversation.

## Project purpose

PowerShell + Microsoft Graph automation toolkit for daily M365 administration:
bulk user onboarding, security posture audits, employee offboarding.
Built and tested against a personal Entra ID tenant. Designed as a portfolio
piece demonstrating production-style patterns (idempotency, retry, caching,
audit logging).

## Tech stack

- **Runtime**: PowerShell 7.x (cross-platform)
- **API client**: `Microsoft.Graph` SDK (v2.x)
- **Auth**: Azure AD App Registration with application permissions, client
  secret via interactive `Read-Host -AsSecureString` (dev only)
- **Output formats**: JSON audit logs, Excel reports (`ImportExcel` module)

## Repository layout

```
m365-automation-toolkit/
├── CLAUDE.md                       # this file -- AI pair programmer instructions
├── README.md                       # human-facing project overview
├── setup/
│   └── Connect-M365.ps1            # one-shot interactive auth
├── modules/
│   └── M365Helper/
│       └── Invoke-WithRetry.ps1    # exponential backoff helper for Graph 429s
├── scripts/
│   └── 01-bulk-onboarding/
│       ├── New-BulkEntraUsers.ps1      # v1: simple create
│       ├── Remove-BulkEntraUsers.ps1   # v1: cleanup
│       ├── Test-OnboardingCsv.ps1      # v2: pre-flight validation
│       ├── Invoke-UserOnboarding.ps1   # v2: idempotent reconciliation
│       └── Remove-DuplicateGroups.ps1  # cleanup helper for dev tenant
├── demo-data/
│   ├── new-hires-2026-05.csv          # 10 sample users
│   └── csv-invalid-example.csv         # deliberately broken, for validation demo
├── docs/
│   └── senior-review.md            # gap analysis from a senior M365 engineer POV
├── logs/                           # JSON audit logs (gitignored)
├── dry.ps1, create.ps1, clean.ps1  # short wrappers for v1
└── v2-dry.ps1, v2-create.ps1, v2-validate-bad.ps1  # short wrappers for v2
```

## Core conventions

### Naming

- Functions and scripts: `Verb-Noun` PascalCase (e.g. `New-BulkEntraUsers.ps1`)
- Use approved PowerShell verbs (`Get-Verb`)
- Wrappers in repo root: short kebab-case (`v2-create.ps1`)
- Reports/logs: `{action}-{yyyymmdd-hhmmss}.{ext}`

### Error handling

- Always set `$ErrorActionPreference = 'Stop'` at the top of every script
- Always pass `-ErrorAction Stop` to Graph cmdlets explicitly -- some
  Microsoft.Graph cmdlets emit non-terminating errors that bypass try/catch
- Wrap Graph mutating calls in `Invoke-WithRetry` to absorb HTTP 429 throttling
- Preserve the original exception message in audit logs (split on newline,
  keep the first line for compactness)

### Idempotency

- Every mutating script must support being run multiple times without side
  effects on the second run
- Use the reconciliation pattern: read current state, compare to desired
  state, mutate only the diff
- Audit logs track three states explicitly: `Created`, `Updated`, `NoOp`,
  plus `Failed` for visibility

### Eventual consistency (real-world Graph API gotcha)

- Microsoft Graph filter index lags 1-3 seconds for new objects, 10-30
  seconds for deletes -- both directions matter
- Mitigate with in-memory caching when you know the call pattern in advance
- Sort cache entries by `CreatedDateTime` ASC and dedupe by name
- Implement self-healing retry: if a cached object id returns 404, refetch
  by name and update the cache before retrying

### Logging

- Every run produces a structured JSON audit log under `./logs/`
- Filename pattern: `{operation}-{yyyymmdd-hhmmss}.json`
- Top-level fields: `RunTimestamp`, `DurationSec`, `DryRun`, totals,
  per-row `Results` array
- Logs are gitignored (contain tenant names, user IDs)

## Safety rules

These rules exist because mistakes here are expensive. Follow them strictly.

1. **Never call `Remove-MgUser`, `Remove-MgGroup`, or any mutating cmdlet
   without first verifying the target exists with a `Get-Mg*` query.**
2. **Never call deletion cmdlets without `-DryRun` support in the wrapper
   script.** Wrappers must default to dry-run when ambiguous.
3. **Never hardcode tenant ID, client ID, secrets, or domain names.**
   Read from env vars or interactive prompt.
4. **Never log secrets.** Even client secret IDs are sensitive.
5. **Never use `Write-Host` for data that should be logged.** Use the JSON
   audit log. `Write-Host` is for human progress messages only.
6. **Never trust CSV input.** Always run `Test-OnboardingCsv.ps1` first.
7. **Never bypass `Invoke-WithRetry`** for Graph mutations. Even
   "small" calls can hit 429 in batch operations.

## Known production gaps (intentional, see senior-review.md)

This project deliberately uses interactive `Read-Host` for authentication
because it runs in a developer sandbox. In production, the recommended
patterns would be:

- **CI/CD**: GitHub Actions with OIDC federation to Entra ID (no secret)
- **Scheduled**: Azure Function with Managed Identity + Key Vault reference
- **On-prem**: Service Principal with certificate-based auth

These are documented in `docs/senior-review.md`. Do not "fix" the
interactive auth without explicit instruction -- the current pattern is
the correct choice for the demo context.

## Common tasks for AI pair programming

If asked to add a new script, follow this checklist:

1. Create under `scripts/{NN-area}/Verb-Noun.ps1`
2. Add a comment-based help block (`.SYNOPSIS`, `.DESCRIPTION`, params, examples)
3. `[CmdletBinding()]` and typed `param()` block
4. Set `$ErrorActionPreference = 'Stop'` at the top
5. Connection check: `if (-not (Get-MgContext)) { ... }`
6. Wrap all Graph mutations in `Invoke-WithRetry`
7. Pass `-ErrorAction Stop` to every Graph cmdlet
8. Write a JSON audit log to `./logs/{operation}-{timestamp}.json`
9. Add a short wrapper in the repo root (e.g. `audit.ps1`)
10. Update `README.md` with the new wrapper and a one-line description

## What NOT to do

- Do not add `Start-Sleep` as a band-aid for eventual consistency.
  Use proper retry with self-healing instead.
- Do not split a single logical operation across multiple scripts.
  Reconciliation belongs in one place.
- Do not introduce new third-party PowerShell modules without
  documenting them in `README.md` Quick Start.
- Do not write code that depends on network-mounted paths,
  Windows-specific features, or non-cross-platform syntax.
- Do not use `ConvertFrom-Json` / `ConvertTo-Json` without `-Depth 5`
  or higher -- the default truncates nested data.

## Iteration log

- v1 (Day 1): basic onboarding + cleanup, ~150 lines, no retry, no validation
- v2 (Day 1 evening): pre-flight validation, retry with backoff, idempotent
  reconciliation, license assignment, manager + group membership
- v2.1 (Day 1 evening): fixed eventual consistency bug in group operations
  with cache + self-healing retry; see commit history and
  `interview-prep/stories/m365-toolkit-eventual-consistency.md`
- v3 (planned): replace interactive auth with `Microsoft.PowerShell.SecretManagement`,
  add `$batch` endpoint for >20 user batches, add Pester tests, GitHub Actions CI
