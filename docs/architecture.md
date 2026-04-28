# Architecture — Production Patterns in M365 Automation

This document explains the design patterns implemented in the toolkit, the trade-offs considered, and what the alternatives would look like in stricter production environments.

The high-level mental model is **Terraform-style reconciliation, but for M365 user lifecycle**: declare desired state in CSV, let the script figure out what to create / update / leave alone, and produce an auditable record per run.

---

## 1. Pre-flight validation

`Test-OnboardingCsv.ps1` runs before any Graph API call. Bad input never crosses the network boundary.

**Checks:**
- Required columns exist (schema)
- No duplicate `MailNickname` rows (uniqueness)
- `MailNickname` matches the UPN naming convention (regex)
- `Department` is in a whitelist (lookup)
- `UsageLocation` is a valid ISO 3166-1 alpha-2 code (semantic)

**Why this matters:** the cost of a failed validation is microseconds locally; the cost of a partial-success run halfway through 1000 users is hours of manual reconciliation. Push errors as far left as possible.

**Alternative:** JSON Schema with strict mode, or a typed input via PowerShell parameter binding. CSV was chosen because admins receive new-hire lists in spreadsheets, not in JSON.

---

## 2. Retry with exponential backoff

`modules/M365Helper/Invoke-WithRetry.ps1` wraps every mutating Graph call. Behavior:

- Honors the `Retry-After` header on HTTP 429 / 503 (Microsoft tells us how long to wait)
- Falls back to exponential backoff with jitter when no header is present (avoids thundering-herd retry storms across parallel scripts)
- Re-throws non-throttling errors immediately (don't paper over real bugs with retries)
- Caps total attempts to prevent infinite loops on permanently broken state

**Why exponential + jitter:** synchronized retries from many clients DDoS the API on its way back up. Jitter (random offset added to each backoff) breaks the synchronization.

**Alternative:** Polly-style retry with circuit breakers. Polly doesn't exist in PowerShell natively, so the helper rolls its own minimum viable version.

---

## 3. Idempotent reconciliation

The main onboarding script (`Invoke-UserOnboarding.ps1`) treats the CSV as **desired state**. For each row it determines:

- **CREATE** — user doesn't exist anywhere yet
- **UPDATE** — user exists but has drifted (department changed, manager moved, license expired)
- **NoOp** — user exists and matches desired state exactly

Running the same CSV twice produces zero side effects on the second run. This is the same philosophy as `terraform apply`.

**Drift detection** is field-by-field, not whole-row replacement. If the user's `JobTitle` changed but `Department` didn't, only `JobTitle` is patched. This minimizes the surface area for unintended changes (and reduces audit-log noise).

**Why idempotency matters:** real-world workflows include resubmission (HR resends the same CSV next week with a new hire added), partial failure recovery (run died at row 7, restart from row 1 safely), and disaster recovery (re-apply the entire desired state to verify).

**Alternative:** versioned migrations (Liquibase-style). Overkill for user lifecycle where there's no concept of "schema version."

---

## 4. Eventual-consistency safety (the most interesting part)

Microsoft Graph is a distributed system. Filter indexes lag for several seconds in both directions:

- A freshly-created group may not appear in the filter index (CREATE lag — searching by name returns 0 hits even though the group exists)
- A deleted group may still appear in the filter index (DELETE lag — searching returns a stale ID that 404s on use)

This caused a real bug during initial development: bulk onboarding worked the first time but failed intermittently on the second run, with `404 Request_ResourceNotFound` on `New-MgGroupMember` calls referring to groups the script had just verified existed. The root cause was identified by reading the `x-ms-ags-diagnostic` header — Microsoft's diagnostic envelope that includes which backend datacenter served the request and which index version it consulted.

The fix has two layers:

### Layer 1: In-memory cache populated once per run

At the start of each onboarding run, list all candidate groups (`Dept-*`), sort by `CreatedDateTime` ASC, and deduplicate by display name. The cache is the **source of truth for the duration of the run**, ignoring the filter index entirely.

**Sort by `CreatedDateTime` ASC matters** because if two groups exist with the same name (transient state during recreation), we always prefer the older one and let the run write the latest authoritative cache entry by display name.

### Layer 2: Self-healing on 404

If `New-MgGroupMember` returns `404 Request_ResourceNotFound` despite the cached ID being correct (because the group was deleted and recreated between the cache snapshot and the call), the loop:

1. Refetches the group by display name (forcing a fresh index read)
2. Updates the in-memory cache entry
3. Retries the membership add once

If the second attempt also 404s, it's a real error and gets logged with full context.

**Why both layers:** Layer 1 alone fails when the cache is too cold (group was deleted after pre-load). Layer 2 alone is too slow when the cache would have worked (refetch cost on every call). Together they handle the common case fast and the edge case correctly.

**Alternative:** consistent reads (`ConsistencyLevel: eventual` header on Graph). Microsoft's documentation suggests this for advanced queries, but it's not guaranteed for membership operations. The cache-plus-self-heal pattern is more reliable in practice.

---

## 5. Structured audit logs

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
  "Results": [...]
}
```

Each `Result` records the user, what action was taken, what changed (if Update), and the timestamp. No `Write-Host` for production paths — every operation that matters goes through the structured logger.

**Why JSON not text logs:** SIEM ingestion (Splunk, Sentinel) parses JSON natively. Compliance evidence is queryable. Free-text logs are write-only.

**Sample sanitized log:** [`docs/sample-audit-log.json`](sample-audit-log.json).

**Alternative:** OpenTelemetry traces with span attributes. Better for distributed systems; overkill for a single-script tool.

---

## Trade-offs at a glance

| Pattern | This toolkit (dev sandbox) | Production-grade alternative |
|---|---|---|
| Auth | Interactive `Read-Host` for client secret | OIDC federation / Managed Identity / Cert auth |
| Cache | In-memory, single-run | Redis / external cache (multi-tenant) |
| Retry | Custom helper with jitter | Polly-style with circuit breaker |
| Reconciliation | CSV-as-desired-state | Git-as-desired-state with PR-driven apply |
| Concurrency | Sequential | `$batch` endpoint or parallel runspaces |
| Tests | Pester unit (planned) | Pester + integration + canary tenant |
| Logging | Local JSON | SIEM ingestion + structured logger + tracing |
| Secrets | One-shot `Read-Host` (sandbox) | SecretManagement vault / KeyVault references |

---

## Future evolution (Roadmap v3)

| Item | Why |
|---|---|
| `SecretManagement` for credentials | Eliminates plaintext-in-memory after auth |
| `$batch` endpoint for bulk ops | Up to 20 sub-requests per call; 5–10× faster on bulk operations |
| Pester unit + integration tests | Confidence + CI gating before merge |
| GitHub Actions OIDC | Unattended runs without long-lived secrets |
| Metrics export | Prometheus / Application Insights for ops dashboards |
| `--apply-from-git` mode | True GitOps: a CSV in a git repo as authoritative state |

---

## What this document is for

A reference for the human author (future-me, debugging in 6 months) and for reviewers who want to understand the **design**, not just the **code**. The README explains *what* the toolkit does; this document explains *why* the patterns are what they are, and what the obvious next step would be in a stricter context.
