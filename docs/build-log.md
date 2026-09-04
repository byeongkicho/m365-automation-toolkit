# Build Log

> Real bugs, design decisions, and lessons encountered while building and hardening this toolkit. Updated as new things happen. Each entry: **symptom → root cause → fix → takeaway.**

This document is for future-me first, reviewers second. The honesty is the point.

---

## 2026-09-04 -- Cloud-only assumptions: capacity and hybrid

This round did not start from a failure. It started from an interview question.
An M365 engineer asked how this toolkit handles Graph idempotency and 504s, and
separately how one would roll M365 out to a **300-person customer**. Answering
honestly meant reading the code instead of remembering it, and the read surfaced
two assumptions the toolkit had never questioned.

Both gaps share a shape: **the toolkit was built and tested against a small,
cloud-only tenant**, and both only bite at a scale or in a topology it never saw.

### Gap 1: seat capacity was never checked

**Symptom.** None yet -- this has not fired, because the test tenant never ran
out of seats. It fires on the first real batch that exceeds the subscription.

**Root cause.** The onboarding script pre-fetches the SKU catalog, but only reads
`SkuPartNumber -> SkuId`. It never asks `PrepaidUnits` / `ConsumedUnits`. That is
fine until seats run out, and Graph does not fail a bulk run as a unit -- it
fails **per user, partway through**. A 300-row CSV against 250 free seats creates
250 licensed users and 50 accounts that exist with no license, and the operator
learns about it from the new hires.

**Fix.** `modules/M365Helper/Test-LicenseCapacity.ps1`: `Get-LicenseCapacity`
turns `Get-MgSubscribedSku` output into per-SKU availability, `Test-LicenseCapacity`
compares it against what the CSV asks for. Wired into `Invoke-UserOnboarding.ps1`
**before any user is created**; the run aborts unless `-IgnoreLicenseCapacity` is
passed. 12 Pester tests.

**Takeaway.**
- `PrepaidUnits` has three states and **only `Enabled` is assignable**. Seats in
  `Warning` are an expired subscription inside its grace period: Graph *accepts*
  assignments against them, and they stop working when the grace period ends.
  Counting them as available is the subtle version of this bug.
- "Not in the tenant at all" and "out of seats" need different fixes (a CSV typo
  vs. a purchase), so they are reported as different statuses.

### Gap 2: every script assumed a cloud-only tenant

**Symptom.** In a hybrid tenant, offboarding reports success and the leaver can
sign in the next morning.

**Root cause.** `onPremisesSyncEnabled` appeared **zero times** in the codebase.
For a user synchronized by Entra Connect, on-premises AD is authoritative for
most attributes including `accountEnabled`. So:

```
Update-MgUser -AccountEnabled:$false   ->  Graph accepts it
log writes "[1] Account disabled"      ->  operator believes offboarding ran
next sync cycle (~30 min)              ->  on-prem value wins, account is live
```

This is worse than an error, because an error would have been noticed.

**Fix.** `modules/M365Helper/Test-DirectorySyncGuard.ps1`. Three functions:
`Test-UserIsSynced` (and whether we even *know* -- a property that was never
requested is not evidence of a cloud-only user), `Test-DirectorySyncGuard`
(splits an intended write into what will stick and what gets reverted), and
`Get-OffboardingSyncImpact` (offboarding gets an explicit answer because a
silent revert there is a security incident, not an inconvenience).
Wired into onboarding drift-update and offboarding; `onPremisesSyncEnabled`
added to both `-Property` lists. 12 Pester tests.

**Takeaway.**
- **"The call succeeded" and "the value is still there in 30 minutes" are
  different claims.** Only the second one is what the log implies.
- Session revocation is *not* listed as ineffective -- it is a cloud-side
  operation and does work. Overstating the blast radius would have been the same
  class of error as missing it. It only buys time, and the guidance says so.
- The guard is deliberately conservative: a field is called cloud-manageable
  only when it is cloud-only by nature, because wrongly promising that a write
  will persist is the expensive direction.

### Bug found while wiring: assigning to a property that does not exist

**Symptom.** `$result.SyncWarning = $syncImpact.Guidance` would have thrown
`The property 'SyncWarning' cannot be found on this object.`

**Root cause.** `[PSCustomObject]@{...}` does not accept new properties by
assignment; the offboarding result object had no such field.

**Fix.** Added `SyncWarning` to the result object's definition -- which is better
anyway, since the warning now lands in the **audit log** rather than scrolling
past on the console.

**Takeaway.** Caught by checking the object definition before running, not by
running. Worth confirming the failure explicitly (`$r=[PSCustomObject]@{A=1}; $r.B='x'`)
rather than assuming PowerShell would be permissive.

### What this round deliberately did NOT do

Listed so the omissions are visible rather than implied:

| Gap | Why it matters | Status |
|---|---|---|
| `$batch` requests | 300 users = 300 round trips; Graph recommends batching up to 20 | **not done** |
| Soft-deleted user collision | A deleted user is recoverable for 30 days; recreating the same UPN fails | **not done** |
| Mailbox / OneDrive retention on offboard | Removing all groups can strip a group-based license, and mailbox data follows the license | **not done** -- highest-risk remaining gap |
| `ShouldProcess` / `-WhatIf` | The scripts use a hand-rolled `-DryRun` instead of the PowerShell convention | **not done** |
| HTTP 504 | `Invoke-WithRetry` treats only 429/503 as retryable; everything else re-throws | **not done, by choice** -- see note |

On 504 specifically: a gateway timeout means the request may have been processed
without a response reaching us, so blind retry risks duplicates. That is safe
here *only because* the operations are idempotent -- which is the actual reason
to add it, and the reason it is a deliberate omission rather than an oversight.

## 2026-04-28 — Pester + CI hardening round

The toolkit already shipped onboarding, security audit, and offboarding scripts. This round added Pester unit tests, PSScriptAnalyzer linting, a 3-stage CI pipeline, Mermaid architecture diagrams, and a deep-dive `architecture.md`. Six commits.

Three real bugs surfaced.

### Bug 1: `microsoft/setup-powershell` action does not exist

**Symptom.** All three CI jobs (`syntax-check`, `lint`, `test`) failed at the "Set up job" stage in 6–7 seconds with:

```
Unable to resolve action microsoft/setup-powershell, repository not found
```

**Root cause.** I assumed there was an official Microsoft `setup-powershell` GitHub Action analogous to `actions/setup-node` or `actions/setup-python`. There isn't.

**Fix.** Removed the step entirely. `ubuntu-latest` runners ship with PowerShell 7.x pre-installed, so `shell: pwsh` alone is sufficient.

```yaml
# Before (broken)
- uses: microsoft/setup-powershell@v1
- name: ...
  shell: pwsh

# After (works)
- name: ...
  shell: pwsh
```

**Takeaway.**
- Verify external action existence before referencing it (a quick `gh api repos/microsoft/setup-powershell` would have caught this).
- Know what comes pre-installed on standard runners. Ubuntu 24.04 LTS on GitHub-hosted runners includes PowerShell 7, .NET, Python, Node, Go, Java — `setup-*` actions are needed only for non-default versions.
- The 7-second failure was actually a gift — it failed loudly at the very first action resolution. Slow failures hide; fast failures teach.

---

### Bug 2: Pester 5 scope — helper functions outside `BeforeAll`

**Symptom.** 12 of 13 `Test-OnboardingCsv.Tests.ps1` tests failed with:

```
CommandNotFoundException: The term 'New-TestCsv' is not recognized
as a name of a cmdlet, function, script file, or executable program.
```

The one test that passed was the only one that didn't reference the helper.

**Root cause.** I defined `function New-TestCsv` as a direct child of `Describe`, assuming it would be in scope for all `Context`/`It` blocks beneath it. **Pester 5 doesn't work that way.** Helper functions live in `BeforeAll {}` blocks; functions defined elsewhere in the test file aren't hoisted into the test container's scope.

**Fix.** Moved the function definition into a `BeforeAll {}` inside `Describe`:

```powershell
Describe 'Test-OnboardingCsv' {

    BeforeAll {
        function New-TestCsv {
            param([string]$Content, [string]$Name = 'test.csv')
            ...
        }
    }

    Context 'Schema validation' {
        It '...' { New-TestCsv ... }   # now visible
    }
}
```

**Takeaway.**
- Pester 5 has much stricter scope isolation than Pester 4. The migration guide is worth reading even if you skip the rest of the docs.
- The error message — `CommandNotFoundException` — is misleading. It sounds like a missing module or typo, but the actual cause is a scope leak.
- Lesson learned: when a *single* test passes and *all* others with a shared helper fail, suspect scope before suspecting logic.

---

### Bug 3: PowerShell `-notmatch` is case-insensitive by default ⭐

**Symptom.** New Pester test "rejects MailNickname with uppercase letters" failed:

```
Expected $false, but got $true.
```

The CSV row was `MailNickname=JOHN.SMITH`. The validator was supposed to reject it (regex `^[a-z0-9.]+$`). But `IsValid` came back as `true`.

**Root cause.** PowerShell's `-match` / `-notmatch` operators are **case-insensitive by default**. The regex `^[a-z0-9.]+$` was effectively behaving like `^[a-zA-Z0-9.]+$`. This is a deliberate "user-friendly default" in PowerShell, but it's a footgun in validation code where the *intent* is "lowercase only."

This is the most concrete justification for "write tests" I've personally encountered. The Pester unit test, added perhaps 30 minutes earlier in the same session, caught a real bug that had been silently shipping in the validation script for weeks.

**Fix.** Changed `-notmatch` → `-cnotmatch` (the `c` prefix forces case-sensitive matching). Added a comment so future-me doesn't undo the `c` while "cleaning up":

```powershell
# Before (allowed JOHN.SMITH through)
if ($u.MailNickname -notmatch '^[a-z0-9.]+$') { ... }

# After (correctly rejects uppercase)
# NOTE: -cnotmatch (case-sensitive) is required here. PowerShell's
# default -notmatch is case-insensitive, which would silently allow
# MailNicknames like "JOHN.SMITH" to pass this regex despite the
# intent being lowercase-only. Caught by Pester unit test.
if ($u.MailNickname -cnotmatch '^[a-z0-9.]+$') { ... }
```

**Takeaway.**
- PowerShell's "user-friendly" case-insensitive defaults are dangerous in validation, security, and identity code where exact matching is the *whole point*.
- Always use the `c`-prefixed variants (`-cmatch`, `-cnotmatch`, `-ceq`, `-cne`, etc.) when correctness depends on case.
- This is now the canonical example, in my own code, of "tests pulling their weight on day one." The test was authored after the production code; running it for the first time immediately surfaced a real bug. The cost of writing the test was vastly lower than the cost of a future onboarding run silently creating users with malformed UPNs.
- Cross-language note: JavaScript, Python, Go, Java, Rust regex are all case-sensitive by default. PowerShell's choice is the outlier; treating it as the outlier in your head saves bugs.

---

### Design decision: `Resolve-Path` returns `PathInfo`, not string

When the test bootstrap used `$script:ScriptPath = Resolve-Path '...'` and later invoked it via `& $script:ScriptPath`, the `PathInfo` object usually coerced to string but inconsistently across platforms.

**Fix.** Explicitly extract `.Path`:

```powershell
$script:ScriptPath = (Resolve-Path '...').Path
```

**Takeaway.** When a path value will be passed to `&` or `.` for invocation, normalize to a string explicitly. Avoids platform-specific edge cases on Linux runners that aren't seen on the dev machine.

---

## Meta-observations

### "Tests pull their weight on day one"

The most validating moment of this round was Bug 3 — a Pester test, written 30 minutes before the failure, immediately caught a real bug that had been silently shipping. I had heard this claim about tests for years; this was the first time I experienced it directly on a project I owned end-to-end. Worth the test-writing time for that single catch alone.

The next-best thing about it: the bug fix commit (`fix(validation): make MailNickname regex case-sensitive`) is a self-contained narrative — a future reviewer reading the git log can see exactly what happened, why, and what the test was supposed to do. That commit is now arguably the most useful single artifact in the repo for hiring conversations.

### CI iteration cost vs. local-first dev

First CI run failed in 7 seconds (missing action). Pester install takes 60–90 seconds; running the actual tests takes another 5 seconds. End-to-end iteration on a CI fix: 90 seconds × N attempts. Acceptable but not free.

Lesson for next time: **install Pester locally and run tests before pushing.** A local Invoke-Pester run is sub-second. Doing this would have caught the helper-scope bug (Bug 2) before pushing it through three iterations of CI.

### Commit-as-narrative

Six commits over an evening tell a coherent story:

1. `docs: add CONTRIBUTING` — repo welcomes contributors
2. `docs: add architecture diagrams + architecture.md` — explains *why*
3. `test: add Pester 5 unit tests + strengthen CI` — tests + automation
4. `fix(ci): remove non-existent microsoft/setup-powershell action` — meta-fix to enable the rest
5. `fix(tests): move New-TestCsv helper into BeforeAll for Pester 5 scope` — applying Pester 5 docs
6. `fix(validation): make MailNickname regex case-sensitive` — tests delivering value

Commits 4–6 were unintentional consequences of getting the previous commits right. Together they're more honest than a squashed "Add CI and tests" PR would have been. The build log here makes that honesty searchable.

---

## How to add entries

When something interesting happens — a real bug, a non-obvious design choice, a "huh, didn't expect that" moment — append a section under today's date. Use the structure:

- **Symptom** (what I saw)
- **Root cause** (what was actually wrong)
- **Fix** (the exact change, with code if helpful)
- **Takeaway** (what I'd watch for next time, what this reveals about the system)

The discipline of writing it down forces me to actually understand the bug, not just patch it. That's the value of this document.
