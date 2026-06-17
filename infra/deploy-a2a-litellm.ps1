<#
.SYNOPSIS
    Deploy the through-LiteLLM A2A variant (additive; does not change existing resources).
.DESCRIPTION
    Deploys infra/a2a-litellm.bicep on top of an existing a2a-agent.bicep +
    litellm-foundry.bicep + deploy-client-foundry.ps1 deployment:
      - Registers (idempotently) the dummy specialist in the LiteLLM A2A Agent Gateway
        so it is re-exposed at {litellm}/a2a/dummy-specialist.
      - Deploys a tiny host-root SHIM Container App that serves the agent card and
        forwards message/send to that LiteLLM endpoint (Bearer key injected).
      - Creates a NEW RemoteA2A connection 'dummy-a2a-litellm' on the Scenario 3 client
        account, targeting the shim.
    Reads the LiteLLM URL + Scenario 3 account from infra/scenario-outputs.json and merges
    the new values back into it so scenario3_aigateway_litellm.py can route A2A via LiteLLM.
.NOTES
    Requires Azure CLI. If az is not on PATH, set $env:AZ_CMD to its full path,
    e.g. "C:\Program Files\Microsoft SDKs\Azure\CLI2\wbin\az.cmd"
#>
param(
    [string]$ResourceGroup = "lab-foundry-ai-gateway",
    [string]$DeploymentName = "a2a-dummy-litellm",
    [string]$LitellmMasterKey = "sk-litellm-foundry-poc",
    [string]$AgentName = "dummy-specialist"
)

$ErrorActionPreference = "Stop"
$az = if ($env:AZ_CMD) { $env:AZ_CMD } else { "az" }
$bicep = Join-Path $PSScriptRoot "a2a-litellm.bicep"
$outputsFile = Join-Path $PSScriptRoot "scenario-outputs.json"
$testDir = Join-Path (Split-Path $PSScriptRoot -Parent) "src\test"
$python = Join-Path $testDir ".venv\Scripts\python.exe"

if (-not (Test-Path $outputsFile)) {
    throw "scenario-outputs.json not found. Run deploy-client-foundry.ps1 first."
}
$existing = Get-Content $outputsFile -Raw -Encoding UTF8 | ConvertFrom-Json

# LiteLLM base URL = the MCP url with the trailing '/mcp/' stripped.
$mcpUrl = $existing.sc3McpLitellmUrl
if (-not $mcpUrl) {
    throw "sc3McpLitellmUrl missing from scenario-outputs.json. Run deploy-litellm-foundry.ps1 + deploy-client-foundry.ps1 first."
}
$litellmBase = ($mcpUrl -replace '/mcp/?$', '')
$a2aLitellmEndpoint = "$litellmBase/a2a/$AgentName"

# Direct dummy URL (LiteLLM forwards to this when proxying the agent).
$dummyDirect = $existing.a2aDirectUrl
if (-not $dummyDirect) {
    throw "a2aDirectUrl missing from scenario-outputs.json. Run deploy-a2a.ps1 first."
}

# Scenario 3 account name (derived from its project endpoint host).
$sc3Endpoint = $existing.sc3ProjectEndpoint
if (-not $sc3Endpoint) {
    throw "sc3ProjectEndpoint missing from scenario-outputs.json. Run deploy-client-foundry.ps1 first."
}
$sc3AccountName = ([Uri]$sc3Endpoint).Host.Split('.')[0]

Write-Host "LiteLLM base     : $litellmBase"
Write-Host "A2A endpoint     : $a2aLitellmEndpoint"
Write-Host "SC3 account      : $sc3AccountName"

# 1) Register the dummy specialist in the LiteLLM A2A gateway (idempotent).
Write-Host "`nRegistering '$AgentName' in the LiteLLM A2A gateway..." -ForegroundColor Cyan
$env:LITELLM_BASE_URL = $litellmBase
$env:LITELLM_MASTER_KEY = $LitellmMasterKey
$env:A2A_URL_DIRECT = $dummyDirect
$env:A2A_AGENT_NAME = $AgentName
& $python (Join-Path $testDir "register_a2a_agent.py")

# 2) Deploy the host-root shim + the Scenario 3 RemoteA2A connection.
Write-Host "`nDeploying the through-LiteLLM A2A shim + connection (a minute or two)..." -ForegroundColor Cyan
& $az deployment group create `
    --name $DeploymentName `
    --resource-group $ResourceGroup `
    --template-file $bicep `
    --parameters sc3AccountName=$sc3AccountName a2aLitellmEndpoint=$a2aLitellmEndpoint litellmMasterKey=$LitellmMasterKey `
    --output none

$outputs = & $az deployment group show --name $DeploymentName --resource-group $ResourceGroup --query properties.outputs | ConvertFrom-Json
$a2aLitellmUrl = $outputs.a2aLitellmUrl.value
$sc3A2aLitellmConnId = $outputs.sc3A2aLitellmConnectionId.value

# 3) Merge the new values into scenario-outputs.json (additive).
$existing | Add-Member -NotePropertyName a2aLitellmUrl -NotePropertyValue $a2aLitellmUrl -Force
$existing | Add-Member -NotePropertyName a2aLitellmEndpoint -NotePropertyValue $a2aLitellmEndpoint -Force
$existing | Add-Member -NotePropertyName sc3A2aLitellmConnId -NotePropertyValue $sc3A2aLitellmConnId -Force
$existing | ConvertTo-Json -Depth 10 | Set-Content $outputsFile -Encoding UTF8

Write-Host "`nA2A shim (host root) : $a2aLitellmUrl" -ForegroundColor Green
Write-Host "Forwards to LiteLLM  : $a2aLitellmEndpoint" -ForegroundColor Green
Write-Host "SC3 connection       : $sc3A2aLitellmConnId" -ForegroundColor Green

Write-Host "`nRun the Foundry agent (A2A through LiteLLM):" -ForegroundColor Cyan
Write-Host "  python ../src/test/scenario3_aigateway_litellm.py"
