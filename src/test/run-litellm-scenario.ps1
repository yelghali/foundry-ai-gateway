<#
.SYNOPSIS
    Run the optional two-consumer LiteLLM scenario without changing the APIM suite.
#>
param(
    [switch]$KeepAgents,
    [string]$TerraformDirectory = "",
    [switch]$UseTerraformAdminKey
)

$ErrorActionPreference = "Stop"
$python = Join-Path $PSScriptRoot ".venv\Scripts\python.exe"
$repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$outputsFile = Join-Path $repoRoot "infra\scenario-outputs.json"
if (-not $TerraformDirectory) {
    $TerraformDirectory = Join-Path $repoRoot "litellm-gateway\litellm-azure-private-endpoints"
}
if (-not (Test-Path $python)) {
    throw "Missing src/test/.venv. Create it and install src/test/requirements.txt."
}
if (-not (Test-Path $outputsFile)) {
    throw "Missing infra/scenario-outputs.json. Ask the facilitator to refresh the predeployed lab metadata."
}
$config = Get-Content $outputsFile -Raw -Encoding UTF8 | ConvertFrom-Json
foreach ($name in "litellmBaseUrl", "litellmModel", "litellmMcpUrl", "litellmA2aShimUrl") {
    if (-not $config.$name) {
        throw "Missing '$name'. Ask the facilitator to refresh the predeployed lab metadata."
    }
}

$loadedAdminKey = $false
$previousMasterKey = [Environment]::GetEnvironmentVariable("LITELLM_MASTER_KEY", "Process")
$previousKeepAgent = [Environment]::GetEnvironmentVariable("KEEP_AGENT", "Process")
try {
    if (-not $env:LITELLM_API_KEY) {
        if (-not $UseTerraformAdminKey) {
            throw "Set LITELLM_API_KEY to a facilitator-issued scoped key. Maintainers with local Terraform state may pass -UseTerraformAdminKey."
        }
        $tfArg = "-chdir=$TerraformDirectory"
        $masterKeyOutput = @(& terraform $tfArg output -raw litellm_master_key)
        if ($LASTEXITCODE -ne 0 -or $null -eq $masterKeyOutput) {
            throw "Could not read the LiteLLM administrator key from Terraform state."
        }
        $masterKey = ($masterKeyOutput | Out-String).Trim()
        if (-not $masterKey) {
            throw "The LiteLLM administrator key Terraform output is empty."
        }
        $loadedAdminKey = $true
        $env:LITELLM_MASTER_KEY = $masterKey
        $masterKey = $null
    }
    $env:KEEP_AGENT = if ($KeepAgents) { "1" } else { "0" }

    foreach ($script in @(
        "scenario6_maf_litellm.py",
        "scenario6_foundry_litellm.py",
        "scenario6_litellm_security.py"
    )) {
        Write-Host "`n=== $script ===" -ForegroundColor Cyan
        & $python (Join-Path $PSScriptRoot $script)
        if ($LASTEXITCODE -ne 0) {
            throw "$script failed with exit code $LASTEXITCODE."
        }
    }
} finally {
    if ($loadedAdminKey) {
        if ($null -eq $previousMasterKey) {
            Remove-Item Env:LITELLM_MASTER_KEY -ErrorAction SilentlyContinue
        } else {
            $env:LITELLM_MASTER_KEY = $previousMasterKey
        }
    }
    if ($null -eq $previousKeepAgent) {
        Remove-Item Env:KEEP_AGENT -ErrorAction SilentlyContinue
    } else {
        $env:KEEP_AGENT = $previousKeepAgent
    }
}

Write-Host "`nOptional LiteLLM two-consumer scenario passed." -ForegroundColor Green
