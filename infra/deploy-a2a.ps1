<#
.SYNOPSIS
    Deploy a dummy A2A agent behind APIM (scenario: gateway governs agent-to-agent traffic).
.DESCRIPTION
    Deploys infra/a2a-agent.bicep on top of an existing main.bicep deployment:
      - A stdlib-only A2A agent (src/a2a/dummy_agent.py) on Azure Container Apps (public HTTPS)
      - An APIM passthrough API ('dummy-a2a') so the gateway proxies the A2A agent
    Reads the APIM service name from the main deployment outputs.
.NOTES
    Requires Azure CLI. If az is not on PATH, set $env:AZ_CMD to its full path,
    e.g. "C:\Program Files\Microsoft SDKs\Azure\CLI2\wbin\az.cmd"
#>
param(
    [string]$ResourceGroup = "lab-foundry-ai-gateway",
    [string]$MainDeploymentName = "backend-pool-load-balancing",
    [string]$DeploymentName = "a2a-dummy-agent"
)

$ErrorActionPreference = "Stop"
$az = if ($env:AZ_CMD) { $env:AZ_CMD } else { "az" }
$bicep = Join-Path $PSScriptRoot "a2a-agent.bicep"

Write-Host "Reading APIM service name from main deployment '$MainDeploymentName'..." -ForegroundColor Cyan
$mainOutputs = & $az deployment group show --name $MainDeploymentName --resource-group $ResourceGroup --query properties.outputs | ConvertFrom-Json
$apimName = $mainOutputs.apimServiceName.value
if (-not $apimName) {
    throw "Could not read apimServiceName from the main deployment outputs."
}
Write-Host "APIM service: $apimName"

Write-Host "Deploying dummy A2A agent Container App + APIM passthrough (a few minutes)..." -ForegroundColor Cyan
& $az deployment group create `
    --name $DeploymentName `
    --resource-group $ResourceGroup `
    --template-file $bicep `
    --parameters apimServiceName=$apimName `
    --output none

$outputs = & $az deployment group show --name $DeploymentName --resource-group $ResourceGroup --query properties.outputs | ConvertFrom-Json
$directUrl = $outputs.a2aAgentDirectUrl.value
$apimUrl = $outputs.a2aAgentApimUrl.value

Write-Host "`nDummy A2A agent (direct) : $directUrl" -ForegroundColor Green
Write-Host "Dummy A2A agent (APIM)   : $apimUrl" -ForegroundColor Green

Write-Host "`nTest the agent card through APIM:" -ForegroundColor Cyan
Write-Host "  curl '$apimUrl/.well-known/agent-card.json' -H 'api-key: <subscription-key>'"
Write-Host "`nRun the client agents:" -ForegroundColor Cyan
Write-Host "  `$env:A2A_URL_APIM = '$apimUrl'      ; python ../src/test/agent_a2a_apim.py"
Write-Host "  `$env:A2A_URL_DIRECT = '$directUrl'  ; python ../src/test/agent_a2a_litellm.py"
