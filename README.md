# M365 Automation Toolkit

> Production-style PowerShell scripts for daily Microsoft 365 administration
> via the Microsoft Graph API. Built and tested against a personal Entra ID
> tenant. Demonstrates idempotent reconciliation, retry on throttling,
> in-memory caching for eventual-consistency safety, and structured audit logs.

## Why this exists

Manually managing M365 environments -- creating users, auditing security
posture, offboarding employees -- consumes hours per week and is error-prone.
This toolkit turns those workflows into reproducible, auditable scripts.

It also exists as a reference for what "production-style" looks like at the
script level: pre-flight validation, retry with backoff, idempotency,
self-healing on stale cache, structured JSON audit logs.

## Headline metrics

| Operation | Manual | Automated | Speedup |
|---|---|---|---|
| Bulk user onboarding (10 users, full lifecycle) | ~30 min | **6.34 sec** | **284x** |
| Same operation, second run (NoOp / idempotent) | -- | **<5 sec** | -- |
| Pre-flight validation of a 10-row CSV | ~5 min | **<1 sec** | -- |
| Security posture audit (5 checks, 11 users) | ~4 hours (manual) | **5.03 sec** | **~2800x** |

Lifecycle covered per user: create account → set department/title → assign
license (when SKU available) → set manager → add to departmental security
group. All idempotent, all logged.

## Tech stack

- **PowerShell 7.x** (cross-platform: macOS, Linux, Windows)
- **Microsoft Graph SDK for PowerShell** (`Microsoft.Graph` v2.x)
- **Azure AD App Registration** with application permissions
- **JSON audit logs** for every operation

## Quick start

### 1. Prerequisites

- PowerShell 7+ (`pwsh`)
- An Entra ID tenant with admin access
- An App Registration with these Graph application permissions, all granted
  admin consent:
  - `User.ReadWrite.All`
  - `Group.ReadWrite.All`
  - `Directory.Read.All`
  - `AuditLog.Read.All`
  - `Organization.Read.All`

### 2. Install dependencies

```powershell
Install-Module Microsoft.Graph -Scope CurrentUser
Install-Module ImportExcel  -Scope CurrentUser
```

### 3. Authenticate

```powershell
./setup/Connect-M365.ps1
```

You will be prompted for Tenant ID, Client ID, and Client Secret Value.

### 4. Run the wrappers

```powershell
./validate-bad.ps1   # Demo: pre-flight rejects a deliberately broken CSV
./dry.ps1            # Preview what onboarding would do (no changes)
./create.ps1         # Run idempotent onboarding for the demo CSV
./create.ps1         # Run again -> all NoOp, proves idempotency
./clean.ps1          # Remove the demo users
./dedupe-groups.ps1  # Cleanup helper for duplicate Dept-* groups
```

## Repository layout

```
m365-automation-toolkit/
├── CLAUDE.md                       # AI pair-programming instructions
├── README.md                       # this file
├── setup/
│   └── Connect-M365.ps1            # one-shot interactive auth
├── modules/
│   └── M365Helper/
│       └── Invoke-WithRetry.ps1    # exponential backoff for Graph 429
├── scripts/
│   └── 01-bulk-onboarding/
│       ├── Test-OnboardingCsv.ps1       # pre-flight validation
│       ├── Invoke-UserOnboarding.ps1    # main: idempotent reconciliation
│       ├── New-BulkEntraUsers.ps1       # v1, kept for reference
│       ├── Remove-BulkEntraUsers.ps1    # cleanup
│       └── Remove-DuplicateGroups.ps1   # dedupe helper
├── demo-data/
│   ├── new-hires-2026-05.csv            # 10 sample users
│   └── csv-invalid-example.csv          # deliberately broken, validation demo
├── docs/
│   └── senior-review.md            # gap analysis from a senior M365 POV
├── logs/                           # JSON audit logs (gitignored)
│   └── 02-security-audit/
│       └── Get-SecurityPosture.ps1      # 5-check security audit → JSON + Excel
├── dry.ps1, create.ps1, clean.ps1
├── audit.ps1, audit-dry.ps1            # Security audit wrappers
├── validate-bad.ps1, dedupe-groups.ps1
```

## Design highlights

### 1. Pre-flight validation

`Test-OnboardingCsv.ps1` runs before any API call. It checks:

- Required columns exist
- No duplicate `MailNickname` rows
- `MailNickname` matches the UPN naming convention
- `Department` is in a whitelist
- `UsageLocation` is a valid ISO 3166-1 alpha-2 code

Bad input never reaches the API.

```
=== Validation Result ===
IsValid: False
Errors found: 5
  - Duplicate MailNickname in CSV: john.smith (appears 2 times)
  - Row 2: empty value in column 'DisplayName'
  - Row 5: invalid MailNickname 'JOHN_BAD' (use lowercase letters, digits, dots)
  - Row 6: invalid Department 'UnknownDept'
  - Row 7: invalid UsageLocation 'XX'
```

### 2. Retry with exponential backoff

`Invoke-WithRetry` wraps every Graph mutation. It:

- Honors the `Retry-After` header on HTTP 429 / 503
- Falls back to exponential backoff with jitter
- Re-throws non-throttling errors immediately

### 3. Idempotent reconciliation

The main script (`Invoke-UserOnboarding.ps1`) treats the CSV as desired state.
For each row it determines whether to **CREATE**, **UPDATE** (only the drifted
fields), or **NoOp**. Running the same CSV twice produces zero side effects
on the second run.

This is the same philosophy as Terraform `apply`.

### 4. Eventual consistency safety

Microsoft Graph is a distributed system. Filter indexes lag for several
seconds in both directions:

- A freshly-created group may not appear in the filter index (CREATE lag)
- A deleted group may still appear in the filter index (DELETE lag)

The script handles this with two patterns:

1. **In-memory cache** populated once at the start of the run, sorted by
   `CreatedDateTime` ASC and deduped by name. The cache is the source of
   truth for the duration of the run.
2. **Self-healing retry**: if `New-MgGroupMember` returns `404
   Request_ResourceNotFound`, the loop refetches the group by name,
   updates the cache, and retries.

This was discovered the hard way; see the debugging story in
`docs/senior-review.md`.

### 5. Structured audit logs

Every run produces a timestamped JSON file under `./logs/`:

```json
{
  "Version": "2.0",
  "RunTimestamp": "2026-04-10T16:47:36+09:00",
  "DurationSec": 6.34,
  "Domain": "contoso.onmicrosoft.com",
  "TotalUsers": 10,
  "CreatedCount": 0,
  "UpdatedCount": 0,
  "NoOpCount": 10,
  "FailCount": 0,
  "Results": [
    {
      "DisplayName": "Minsu Kim",
      "UserPrincipalName": "minsu.kim@contoso.onmicrosoft.com",
      "Status": "NoOp",
      "Actions": "noop",
      "Timestamp": "2026-04-10T16:47:36+09:00"
    }
  ]
}
```

These are intentionally machine-readable so they can be ingested by SIEM,
Splunk, or used as compliance evidence.

## What this is NOT (and why)

This project deliberately uses interactive `Read-Host` for the Client Secret
because it runs in a developer sandbox. **In production environments the
recommended patterns are:**

- **CI/CD**: GitHub Actions with OIDC federation to Entra ID -- no secret at all
- **Scheduled**: Azure Function with Managed Identity + Key Vault reference
- **On-premises**: Service Principal with certificate auth, never client secret

See `docs/senior-review.md` for the full production gap analysis.
The interactive auth is a deliberate trade-off, not an oversight.

## Script: Security Posture Audit

`Get-SecurityPosture.ps1` performs five automated security checks:

| Check | What it detects | Severity |
|---|---|---|
| MFA registration | Active users without MFA | High |
| Inactive accounts | No sign-in for 90+ days (or creation age on free tenants) | Medium |
| Privileged roles | Global Admin, User Admin, Security Admin, etc. | Critical |
| Guest accounts | External B2B users | Low |
| Password policy | Accounts with password-never-expires | Medium |

Outputs: console summary, JSON audit log, and Excel workbook with one sheet
per finding category. Gracefully degrades on free Entra ID tenants (no
`SignInActivity` → falls back to `CreatedDateTime`).

```
./audit.ps1          # Full audit → Console + JSON + Excel
./audit-dry.ps1      # Preview checks without querying Graph
```

## Roadmap

- [x] **Day 1 v1** -- basic onboarding + cleanup
- [x] **Day 1 v2** -- pre-flight validation, retry, idempotency, license/group/manager
- [x] **Day 1 v2.1** -- fixed eventual-consistency bug with cache + self-healing
- [x] **CLAUDE.md** -- project-level instructions for AI pair programming
- [x] **Day 2** -- security posture audit (5 checks, JSON + Excel output, free-tier graceful degradation)
- [ ] **Day 3** -- automated offboarding workflow
- [ ] **v3** -- replace interactive auth with `SecretManagement`, add `$batch` endpoint, Pester tests, GitHub Actions CI

## How this was built

Built as a portfolio project with Claude as a pair programmer. The
architectural decisions, debugging, and pattern selection were mine; Claude
accelerated the typing and helped me look up Graph SDK syntax. The most
interesting moment was diagnosing an eventual-consistency bug in group
membership operations -- documented in `docs/senior-review.md`.

## License

MIT

## Author

Byeongki "Ki" Cho -- bilingual cloud and infrastructure engineer in Seoul.
[LinkedIn](https://www.linkedin.com/in/byeongkicho)
