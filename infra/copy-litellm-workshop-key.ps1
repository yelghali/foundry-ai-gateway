<#
.SYNOPSIS
    Copy the facilitator's scoped LiteLLM workshop key to the Windows clipboard.
.DESCRIPTION
    Decrypts the user-bound DPAPI credential created by deploy-litellm-scenario.ps1.
    The key is not printed. Share it only through the workshop's approved secret channel.
#>
param(
    [string]$WorkshopKeyFile = ""
)

$ErrorActionPreference = "Stop"
if (-not $WorkshopKeyFile) {
    $WorkshopKeyFile = Join-Path $env:LOCALAPPDATA "foundry-ai-gateway\litellm-workshop-key.clixml"
}
if (-not (Test-Path $WorkshopKeyFile)) {
    throw "The DPAPI-protected workshop key was not found. Run infra/deploy-litellm-scenario.ps1 first."
}

$storedCredential = Import-Clixml $WorkshopKeyFile
if ($storedCredential -isnot [System.Management.Automation.PSCredential]) {
    throw "The stored workshop key is not a DPAPI-protected PowerShell credential."
}
$workshopKey = $storedCredential.GetNetworkCredential().Password
try {
    Set-Clipboard -Value $workshopKey
} finally {
    $workshopKey = $null
}

Write-Host "The scoped LiteLLM workshop key is on the clipboard; its value was not displayed." -ForegroundColor Green