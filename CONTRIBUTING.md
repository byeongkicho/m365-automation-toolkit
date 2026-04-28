# Contributing

Thanks for your interest. This toolkit was built and tested against my personal Entra ID tenant; it's open-sourced because the patterns (idempotent reconciliation, retry on throttling, eventual-consistency caching, structured audit logs) are reusable in many M365 administration scenarios.

## What's helpful

### 1. Bug reports
Microsoft Graph API behavior can drift between SDK versions and tenant configurations. If something breaks:

Please open an [Issue](https://github.com/byeongkicho/m365-automation-toolkit/issues) with:

- Script involved (e.g., `Onboard-Users.ps1`)
- PowerShell version (`$PSVersionTable.PSVersion`)
- Microsoft Graph SDK version (`Get-Module Microsoft.Graph -ListAvailable | Select Version`)
- Full error message + stack trace (redact tenant IDs and user UPNs)
- What you expected vs. what happened

### 2. Feature requests
Open an issue first. Useful angles:

- A new M365 admin workflow that fits the same pattern (idempotent + audited + retry-safe)
- Better diagnostics or telemetry
- Cross-tenant migration helpers

### 3. Pattern discussions
This repo is partly a reference for "what production-style PowerShell looks like." If you disagree with a design choice (e.g., in-memory cache vs. Redis), an issue with reasoning is welcome.

## Code style

- PowerShell 7.x (`pwsh`) — Windows PowerShell 5.1 not supported
- Microsoft Graph SDK v2 (app-permission auth)
- Use approved verbs (`Get-Verb`)
- Idempotency by default — check before you change, never assume create-only
- Wrap Graph API calls in the toolkit's retry helper (handles `429`, `503`, jitter, max attempts)
- Audit logs go through the structured logger — no `Write-Host` for production paths

## Testing

This toolkit was developed against a personal sandbox tenant. **Do not test directly against production.** Recommended setup:

1. Create a free dev Microsoft 365 tenant ([developer.microsoft.com/microsoft-365/dev-program](https://developer.microsoft.com/microsoft-365/dev-program))
2. Register an Entra ID app with appropriate Graph permissions (least privilege per script)
3. Run scripts with `-WhatIf` first if available, or against single test users before bulk operations

## Security

- Never commit secrets, app IDs, tenant IDs, or user data
- Application permissions should be scoped to the minimum needed per workflow
- The toolkit logs operation outcomes but redacts user-identifiable details by default

## Disclosure

This toolkit was built with substantial Claude Code pair-programming: AI helped with PowerShell syntax, Graph API exploration, and test scaffolding. The architectural decisions (cache vs. retry vs. idempotent reconciliation) and the actual debugging — including the Microsoft Graph eventual-consistency bug, which was diagnosed by reading `x-ms-ags-diagnostic` headers and not from an AI suggestion — belong to the human author.
