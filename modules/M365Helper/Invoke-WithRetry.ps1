<#
.SYNOPSIS
    Executes a script block with exponential backoff retry on Microsoft Graph 429 throttling.

.DESCRIPTION
    Wraps Graph API calls in a retry loop. Honors the Retry-After header when present,
    falls back to exponential backoff with jitter otherwise. Re-throws non-throttling errors.

.PARAMETER ScriptBlock
    The script block to execute.

.PARAMETER MaxRetries
    Maximum number of retry attempts. Default 5.

.PARAMETER InitialDelaySec
    Initial delay before the first retry when no Retry-After header is provided. Default 2.

.EXAMPLE
    Invoke-WithRetry -ScriptBlock { New-MgUser @userParams }
#>

function Invoke-WithRetry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$ScriptBlock,

        [Parameter(Mandatory = $false)]
        [int]$MaxRetries = 5,

        [Parameter(Mandatory = $false)]
        [int]$InitialDelaySec = 2
    )

    $attempt = 0
    while ($true) {
        try {
            return & $ScriptBlock
        }
        catch {
            $statusCode = $null
            $retryAfter = $null

            # Try to extract status code from various exception shapes
            if ($_.Exception.Response) {
                $statusCode = [int]$_.Exception.Response.StatusCode
                $retryAfter = $_.Exception.Response.Headers['Retry-After']
            }
            elseif ($_.ErrorDetails.Message -match '"code":\s*"(\d+)"') {
                $statusCode = [int]$matches[1]
            }

            $isThrottled = ($statusCode -eq 429) -or ($statusCode -eq 503)

            if (-not $isThrottled) {
                # Non-throttling error: re-throw immediately
                throw
            }

            $attempt++
            if ($attempt -gt $MaxRetries) {
                Write-Warning "Max retries ($MaxRetries) exceeded after throttling."
                throw
            }

            # Calculate delay: respect Retry-After if present, else exponential backoff with jitter
            if ($retryAfter) {
                $delay = [int]$retryAfter
            } else {
                $delay = [int]([math]::Pow(2, $attempt) * $InitialDelaySec)
                $delay += Get-Random -Minimum 0 -Maximum 2  # jitter
            }

            Write-Warning "Throttled (HTTP $statusCode). Sleeping ${delay}s before retry ${attempt}/${MaxRetries}"
            Start-Sleep -Seconds $delay
        }
    }
}
