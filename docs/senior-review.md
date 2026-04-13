# Senior M365 Engineer Review

> Critique of the current toolkit from a senior M365 / Identity engineer perspective.
> Use this as the roadmap to elevate the project from "junior portfolio" to
> "production-ready reference architecture."

## 🔴 P0 -- Security: Secret Management

**Current state:** Read-Host prompts for the Client Secret on every run. Lives only
in process memory. Fine for a demo, blocks any automation.

**Production patterns:**

| Environment | Where the secret lives |
|---|---|
| Local development | `Microsoft.PowerShell.SecretManagement` + `SecretStore` (encrypted local vault) |
| CI/CD (GitHub Actions) | GitHub Secrets injected as env vars; better: OIDC federation, no secret at all |
| Azure Function / Automation | **Managed Identity** -- the secret literally does not exist |
| On-prem scheduler | Azure Key Vault + Service Principal Certificate |

**Strongest option:** replace Client Secret with **certificate-based auth**. It bypasses
the 90-day rotation policy and satisfies NIST 800-53.

```powershell
# Production pattern
Connect-MgGraph -ClientId $appId `
                -TenantId $tenantId `
                -CertificateThumbprint $certThumbprint
```

---

## 🔴 P0 -- Idempotency: Reconciliation

**Current state:** running the same CSV twice marks duplicates as `[SKIP]`, but
**never updates an existing user whose attributes changed**.

**Standard pattern: reconciliation loop**

```
For each row in CSV:
  if not exists           -> CREATE
  if exists AND drift     -> UPDATE only the changed fields
  if exists AND identical -> NO-OP
  Mark row as processed
```

This is true idempotency. Same philosophy as Terraform / Ansible.

---

## 🟠 P1 -- Throttling and Retry

**Current state:** any Graph API failure goes straight to `[FAIL]`.

**Reality:** Microsoft Graph routinely returns **429 Too Many Requests**, especially
when processing more than ~100 objects.

```powershell
# Retry with exponential backoff respecting Retry-After header
$maxRetries = 5
$attempt = 0
while ($attempt -lt $maxRetries) {
    try {
        New-MgUser @params
        break
    }
    catch {
        if ($_.Exception.Response.StatusCode -eq 429) {
            $retryAfter = [int]$_.Exception.Response.Headers['Retry-After']
            Write-Warning "Throttled. Sleeping ${retryAfter}s before retry $($attempt + 1)/$maxRetries"
            Start-Sleep -Seconds $retryAfter
            $attempt++
        } else {
            throw
        }
    }
}
```

Even better: use `Invoke-MgGraphRequest`'s built-in retry, or wrap calls in a
Polly-style policy module.

---

## 🟠 P1 -- Batch Requests

**Current state:** 10 users = 10 individual API calls. At 100 users you will hit
throttling almost immediately.

**Standard pattern:** the Graph **`$batch`** endpoint -- up to 20 requests per HTTP call.

```powershell
$batchRequests = @()
foreach ($user in $users[0..19]) {
    $batchRequests += @{
        id      = $user.MailNickname
        method  = "POST"
        url     = "/users"
        body    = $newUserParams
        headers = @{ "Content-Type" = "application/json" }
    }
}

Invoke-MgGraphRequest -Method POST `
                      -Uri "/v1.0/`$batch" `
                      -Body @{ requests = $batchRequests }
```

100 users: **10 seconds → ~2 seconds**. Microsoft officially recommends this.

---

## 🟠 P1 -- License Assignment

**Current state:** users are created but no licenses, no groups, no manager.
In real onboarding, **license + group assignment is where 80% of bugs live**.

**Direct assignment:**

```powershell
$license = @{
    AddLicenses = @(
        @{ SkuId = "ENTERPRISEPACK_GUID" }  # E3
    )
    RemoveLicenses = @()
}
Set-MgUserLicense -UserId $user.Id -BodyParameter $license
```

**Modern alternative:** **Group-Based Licensing** (requires Entra ID P1).
Add the user to "Engineering" → license is granted automatically. The script
only manages group membership, which decouples HR data from licensing logic.

---

## 🟡 P2 -- Logging: Structured + Centralized

**Current state:** JSON file dropped in `./logs/`. Useful for one machine, useless
at scale.

**Standard pattern:**

| Layer | Tool |
|---|---|
| Structured logs | **PSFramework** (`Write-PSFMessage`) -- enterprise-grade PowerShell logging |
| Centralized | Azure Monitor / Log Analytics workspace |
| SIEM integration | Splunk HEC, Microsoft Sentinel connector |
| Alerting | Teams Webhook, PagerDuty, Opsgenie on failure |

```powershell
Write-PSFMessage -Level Important `
                 -Message "User created" `
                 -Tag 'onboarding','success' `
                 -Data @{
                     UPN = $upn
                     DurationMs = $stopwatch.ElapsedMilliseconds
                 }
```

Once data is in Log Analytics you can KQL queries like:
"onboarding failure rate over the last 7 days, grouped by department."

---

## 🟡 P2 -- Pre-flight Validation

**Current state:** the CSV is trusted. No schema check, no duplicate detection,
no whitelisting.

**Standard pattern:** validate before you mutate.

```powershell
function Test-OnboardingCsv {
    param($CsvPath)

    $errors = @()
    $users = Import-Csv $CsvPath

    # 1. Schema
    $required = @('DisplayName','MailNickname','GivenName','Surname','Department')
    foreach ($field in $required) {
        if (-not ($users[0].PSObject.Properties.Name -contains $field)) {
            $errors += "Missing required column: $field"
        }
    }

    # 2. Duplicates within the CSV
    $dupes = $users | Group-Object MailNickname | Where-Object Count -gt 1
    foreach ($d in $dupes) { $errors += "Duplicate MailNickname in CSV: $($d.Name)" }

    # 3. UPN format
    $invalid = $users | Where-Object { $_.MailNickname -notmatch '^[a-z0-9.]+$' }
    foreach ($u in $invalid) { $errors += "Invalid MailNickname: $($u.MailNickname)" }

    # 4. Department whitelist
    $validDepts = @('Engineering','Sales','HR','Finance','Marketing')
    $bad = $users | Where-Object { $_.Department -notin $validDepts }
    foreach ($u in $bad) { $errors += "Invalid department: $($u.Department)" }

    return $errors
}
```

Run this in CI on every PR. Bad CSVs never reach prod.

---

## 🟡 P2 -- Lifecycle Triggers (Webhooks)

**Current state:** humans craft a CSV and run a script.

**Standard pattern:** the HR system (Workday, BambooHR) emits a change event →
an Azure Function picks it up → onboarding runs automatically.

```
Workday → Webhook → Azure Function → Graph API → Entra ID
                                   ↓
                              Audit log → Sentinel
```

This is real production lifecycle. Microsoft recommends **Graph change
notifications (webhooks)** or the **Office 365 Management Activity API**
over polling.

---

## 🟢 P3 -- Standard features missing

1. **Welcome email** -- `Send-MgUserMail` to the new hire or their manager with the temporary password
2. **Manager assignment** -- CSV column `ManagerUPN` → `Set-MgUserManagerByRef`
3. **Conditional Access pre-check** -- ensure new users are not blocked by an existing CA policy on first sign-in
4. **MFA enrollment enforcement** -- require MFA registration on first sign-in via the Authentication Methods Policy
5. **Group membership** -- auto-add by department
6. **Mailbox warmup** -- wait for Exchange Online provisioning (1-15 min)
7. **OneDrive pre-provisioning** -- `Request-SPOPersonalSite` so the site exists on day one
8. **Naming conflict resolution** -- two "John Smith" → `john.smith2`, `john.smith3`

---

## High-ROI roadmap for the portfolio

Implementing everything = ~1 week. For a portfolio that signals "senior",
the highest-leverage 5 items are:

| # | Item | Time | Why it matters |
|---|------|------|----------------|
| 1 | Pre-flight CSV validation | 30 min | Senior code smell awareness; "validate at the boundary" |
| 2 | Retry with backoff (429 handling) | 30 min | Real-world experience signal; "knows about throttling" |
| 3 | Idempotent reconciliation (CREATE or UPDATE) | 1 hr | Terraform mindset = infrastructure engineer |
| 4 | License assignment (group-based or direct) | 1 hr | Core onboarding feature; not just identity |
| 5 | Manager + group assignment | 30 min | "Reflects org structure, not just users" |

Total: **3-4 hours**. Lifts the project from "junior toy" to "a senior would respect this".

---

## README section to add

```markdown
## What this is NOT (and why)

This portfolio project deliberately uses interactive Read-Host for credentials
because it runs in a developer sandbox. In production environments the
recommended patterns are:

- **CI/CD**: GitHub Actions with OIDC federation to Entra ID (no secrets at all)
- **Scheduled**: Azure Function with Managed Identity + Key Vault reference
- **On-premises**: Service Principal with certificate auth, never client secret

See `docs/production-architecture.md` for the recommended deployment topology.
```

This single section flips an interview question from "why are you using Read-Host?"
into "I know the right pattern; here is why I chose this for the demo."
That distinction is what separates juniors from seniors.

---

## Sources

- [Microsoft 365 Provisioning Best Practices -- Solutions2Share](https://www.solutions2share.com/microsoft-365-provisioning/)
- [Bulk Create M365 Users with Graph PowerShell -- M365Corner](https://m365corner.com/m365-powershell/create-bulk-users-using-microsoft-graph.html)
- [Automate M365 Lifecycle with PowerShell and Graph -- beefed.ai](https://beefed.ai/en/automate-m365-lifecycle-powershell-graph)
- [Using Azure Key Vault to Secure Graph API Automation -- Sean McAvinue](https://seanmcavinue.net/2021/07/21/using-azure-keyvault-to-secure-graph-api-automation-scripts/)
- [Connect to Graph API securely with Function App + Key Vault -- AppGovScore](https://www.appgovscore.com/blog/connect-to-microsoft-graph-api-securely-function-app-azure-key-vault)
