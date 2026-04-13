<#
.SYNOPSIS
    Removes duplicate Dept-* groups, keeping the oldest one in each name.

.DESCRIPTION
    Cleanup helper for the eventual-consistency bug that produced duplicate
    groups in earlier runs. Lists all Dept-* groups, groups by displayName,
    keeps the one with the earliest CreatedDateTime, deletes the rest.
#>

[CmdletBinding()]
param(
    [switch]$DryRun
)

if (-not (Get-MgContext)) {
    Write-Error "Not connected to Graph."
    exit 1
}

Write-Host ""
Write-Host "=== Removing Duplicate Dept-* Groups ===" -ForegroundColor Cyan
Write-Host ""

$groups = Get-MgGroup -Filter "startsWith(displayName, 'Dept-')" -Property Id,DisplayName,CreatedDateTime -All
Write-Host "Found $($groups.Count) Dept-* groups" -ForegroundColor Gray

$grouped = $groups | Group-Object DisplayName
$toDelete = @()

foreach ($g in $grouped) {
    if ($g.Count -gt 1) {
        $sorted = $g.Group | Sort-Object CreatedDateTime
        $keep = $sorted[0]
        $delete = $sorted[1..($sorted.Count - 1)]
        Write-Host "  $($g.Name): $($g.Count) copies, keeping $($keep.Id)" -ForegroundColor Yellow
        $toDelete += $delete
    }
}

Write-Host ""
Write-Host "Will delete $($toDelete.Count) duplicate groups" -ForegroundColor Yellow
Write-Host ""

foreach ($d in $toDelete) {
    if ($DryRun) {
        Write-Host "  [DRY] Would delete $($d.DisplayName) ($($d.Id))" -ForegroundColor Cyan
    } else {
        try {
            Remove-MgGroup -GroupId $d.Id -ErrorAction Stop
            Write-Host "  [OK]  Deleted $($d.DisplayName) ($($d.Id))" -ForegroundColor Green
        }
        catch {
            Write-Host "  [FAIL] $($d.Id): $($_.Exception.Message)" -ForegroundColor Red
        }
    }
}

Write-Host ""
Write-Host "Done." -ForegroundColor Green
