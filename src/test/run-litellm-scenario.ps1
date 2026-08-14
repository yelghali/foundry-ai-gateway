<#
.SYNOPSIS
    Run the optional two-consumer LiteLLM scenario without changing the APIM suite.
#>
param(
    [switch]$KeepAgents,
    [string]$TerraformDirectory = ""
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
    throw "Missing infra/scenario-outputs.json. Run infra/deploy-litellm-scenario.ps1 first."
}
$config = Get-Content $outputsFile -Raw -Encoding UTF8 | ConvertFrom-Json
foreach ($name in "litellmBaseUrl", "litellmMcpUrl", "litellmA2aShimUrl") {
    if (-not $config.$name) {
        throw "Missing '$name'. Run infra/deploy-litellm-scenario.ps1 first."
    }
}

$tfArg = "-chdir=$TerraformDirectory"
$env:LITELLM_MASTER_KEY = (& terraform $tfArg output -raw litellm_master_key).Trim()
$env:LITELLM_MODEL = (& terraform $tfArg output -raw public_model_name).Trim()
$env:KEEP_AGENT = if ($KeepAgents) { "1" } else { "0" }

try {
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
    Remove-Item Env:LITELLM_MASTER_KEY, Env:LITELLM_MODEL, Env:KEEP_AGENT -ErrorAction SilentlyContinue
}

Write-Host "`nOptional LiteLLM two-consumer scenario passed." -ForegroundColor Green
