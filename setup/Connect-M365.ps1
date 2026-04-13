# Connect-M365.ps1
# One-shot setup script: prompts for Azure App credentials and connects to Microsoft Graph.
# Usage: pwsh ./Connect-M365.ps1

Write-Host ""
Write-Host "=== M365 Automation Toolkit -- Connection Setup ===" -ForegroundColor Cyan
Write-Host ""
Write-Host "You need 3 values from Azure Portal > Entra ID > App registrations:"
Write-Host "  1. Directory (tenant) ID"
Write-Host "  2. Application (client) ID"
Write-Host "  3. Client Secret Value (from Certificates & secrets)"
Write-Host ""

# Prompt for values
$tenantId = Read-Host "Paste Tenant ID"
$clientId = Read-Host "Paste Client ID"
$clientSecret = Read-Host "Paste Client Secret Value" -AsSecureString

# Build credential
$credential = [pscredential]::new($clientId, $clientSecret)

Write-Host ""
Write-Host "Connecting to Microsoft Graph..." -ForegroundColor Yellow

try {
    Connect-MgGraph -TenantId $tenantId -ClientSecretCredential $credential -NoWelcome -ErrorAction Stop

    $context = Get-MgContext
    Write-Host ""
    Write-Host "=== Connected Successfully ===" -ForegroundColor Green
    Write-Host "  Tenant ID:  $($context.TenantId)"
    Write-Host "  Client ID:  $($context.ClientId)"
    Write-Host "  Auth Type:  $($context.AuthType)"
    Write-Host "  Scopes:     $($context.Scopes -join ', ')"
    Write-Host ""

    # Test: list users
    Write-Host "Testing: fetching first 5 users..." -ForegroundColor Yellow
    $users = Get-MgUser -Top 5 -ErrorAction Stop
    Write-Host ""
    Write-Host "Users in tenant:" -ForegroundColor Green
    $users | Select-Object DisplayName, UserPrincipalName | Format-Table -AutoSize

    # Save credentials to session env for later scripts
    $env:TENANT_ID = $tenantId
    $env:CLIENT_ID = $clientId
    # Note: we don't save secret to env for security

    Write-Host ""
    Write-Host "Ready! You are now authenticated to Graph API." -ForegroundColor Green
    Write-Host "Run other scripts from the m365-automation-toolkit directory."
    Write-Host ""
}
catch {
    Write-Host ""
    Write-Host "=== Connection Failed ===" -ForegroundColor Red
    Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host ""
    Write-Host "Common issues:" -ForegroundColor Yellow
    Write-Host "  - Client Secret expired or copied incorrectly"
    Write-Host "  - API permissions not granted admin consent"
    Write-Host "  - Tenant ID or Client ID typo"
    Write-Host ""
    exit 1
}
