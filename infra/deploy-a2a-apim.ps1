<#
.SYNOPSIS
    Deploy the through-APIM A2A variant (additive; does not change existing resources).
.DESCRIPTION
    Deploys infra/a2a-apim.bicep on top of an existing main.bicep + a2a-agent.bicep +
    deploy-client-foundry.ps1 deployment:
      - A NEW APIM API 'dummy-a2a-apim' that reuses the existing dummy-a2a backend and
        rewrites the agent card url so the A2A message leg flows through APIM.
      - A NEW RemoteA2A connection 'dummy-a2a-apim' on the Scenario 1 client account.
    Reads the APIM service name from the main deployment and the Scenario 1 account name
    from infra/scenario-outputs.json, then merges the two new values back into that file
    so the scenario scripts can read them.
.NOTES
    Requires Azure CLI. If az is not on PATH, set $env:AZ_CMD to its full path,
    e.g. "C:\Program Files\Microsoft SDKs\Azure\CLI2\wbin\az.cmd"
#>
param(
    [string]$ResourceGroup = "lab-foundry-ai-gateway",
    [string]$MainDeploymentName = "backend-pool-load-balancing",
    [string]$DeploymentName = "a2a-dummy-apim"
)

$ErrorActionPreference = "Stop"
$az = if ($env:AZ_CMD) { $env:AZ_CMD } else { "az" }
$bicep = Join-Path $PSScriptRoot "a2a-apim.bicep"
$outputsFile = Join-Path $PSScriptRoot "scenario-outputs.json"

Write-Host "Reading APIM service name from main deployment '$MainDeploymentName'..." -ForegroundColor Cyan
$mainOutputs = & $az deployment group show --name $MainDeploymentName --resource-group $ResourceGroup --query properties.outputs | ConvertFrom-Json
$apimName = $mainOutputs.apimServiceName.value
if (-not $apimName) {
    throw "Could not read apimServiceName from the main deployment outputs."
}

if (-not (Test-Path $outputsFile)) {
    throw "scenario-outputs.json not found. Run deploy-client-foundry.ps1 first."
}
$existing = Get-Content $outputsFile -Raw -Encoding UTF8 | ConvertFrom-Json
$sc1Endpoint = $existing.sc1ProjectEndpoint
if (-not $sc1Endpoint) {
    throw "sc1ProjectEndpoint missing from scenario-outputs.json. Run deploy-client-foundry.ps1 first."
}
# Derive the Scenario 1 account name from its project endpoint host.
$sc1AccountName = ([Uri]$sc1Endpoint).Host.Split('.')[0]

Write-Host "APIM service : $apimName"
Write-Host "SC1 account  : $sc1AccountName"

Write-Host "`nDeploying the through-APIM A2A API + connection (a minute or two)..." -ForegroundColor Cyan
& $az deployment group create `
    --name $DeploymentName `
    --resource-group $ResourceGroup `
    --template-file $bicep `
    --parameters apimServiceName=$apimName sc1AccountName=$sc1AccountName `
    --output none

$outputs = & $az deployment group show --name $DeploymentName --resource-group $ResourceGroup --query properties.outputs | ConvertFrom-Json
$a2aApimUrl = $outputs.a2aApimUrl.value
$a2aApimMessageUrl = $outputs.a2aApimMessageUrl.value
$sc1A2aApimConnId = $outputs.sc1A2aApimConnectionId.value

# Merge the new values into scenario-outputs.json (additive).
$existing | Add-Member -NotePropertyName a2aApimUrl -NotePropertyValue $a2aApimUrl -Force
$existing | Add-Member -NotePropertyName a2aApimMessageUrl -NotePropertyValue $a2aApimMessageUrl -Force
$existing | Add-Member -NotePropertyName sc1A2aApimConnId -NotePropertyValue $sc1A2aApimConnId -Force
$existing | ConvertTo-Json -Depth 10 | Set-Content $outputsFile -Encoding UTF8

Write-Host "`nA2A base (host root) : $a2aApimUrl" -ForegroundColor Green
Write-Host "A2A message endpoint : $a2aApimMessageUrl" -ForegroundColor Green
Write-Host "SC1 connection       : $sc1A2aApimConnId" -ForegroundColor Green

Write-Host "`nTest the rewritten agent card through APIM (served at the host root):" -ForegroundColor Cyan
Write-Host "  curl '$a2aApimUrl/.well-known/agent-card.json' -H 'api-key: <subscription-key>'"
Write-Host "`nRun the new Foundry agent (A2A through APIM):" -ForegroundColor Cyan
Write-Host "  python ../src/test/scenario1_a2a_apim.py"
