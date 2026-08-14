<#
.SYNOPSIS
    Run the supported two-consumer APIM workshop path end to end.
#>
param(
    [switch]$KeepAgents
)

$ErrorActionPreference = "Stop"
$python = Join-Path $PSScriptRoot ".venv/Scripts/python.exe"
if (-not (Test-Path $python)) {
    throw "Missing src/test/.venv. Create it and install src/test/requirements.txt."
}

$env:KEEP_AGENT = if ($KeepAgents) { "1" } else { "0" }
$scripts = @(
    "setup_foundry_toolbox.py",
    "scenario1_maf_model_apim.py",
    "scenario1_foundry_model_apim.py",
    "scenario2_maf_mcp_apim.py",
    "scenario2_foundry_mcp_apim.py",
    "scenario3_maf_toolbox_apim.py",
    "scenario3_foundry_toolbox_apim.py",
    "scenario4_maf_enterprise_agent_apim.py",
    "scenario4_foundry_agent_apim.py",
    "scenario5_maf_capstone.py",
    "scenario5_foundry_capstone.py",
    "scenario_security_boundaries.py"
)

foreach ($script in $scripts) {
    Write-Host "`n=== $script ===" -ForegroundColor Cyan
    & $python (Join-Path $PSScriptRoot $script)
    if ($LASTEXITCODE -ne 0) {
        throw "$script failed with exit code $LASTEXITCODE."
    }
}

Write-Host "`nAll two-consumer scenarios passed." -ForegroundColor Green