<#
.SYNOPSIS
    Deploy LiteLLM as a "Bring Your Own Gateway" into Azure AI Foundry.
.DESCRIPTION
    Deploys infra/litellm-foundry.bicep on top of an existing main.bicep deployment:
      - LiteLLM on Azure Container Apps (public HTTPS, managed identity, Entra ID)
      - A Foundry "Model Gateway" connection that points Foundry Agent Service at it
    Reads the two Foundry account names from the main deployment outputs.
.NOTES
    Requires Azure CLI. If az is not on PATH, set $env:AZ_CMD to its full path,
    e.g. "C:\Program Files\Microsoft SDKs\Azure\CLI2\wbin\az.cmd"
#>
param(
    [string]$ResourceGroup = "lab-foundry-ai-gateway",
    [string]$MainDeploymentName = "backend-pool-load-balancing",
    [string]$DeploymentName = "litellm-foundry-gateway",
    [string]$ConnectionName = "litellm-gateway",
    # The key Foundry presents to LiteLLM. Override for anything beyond a POC.
    [string]$MasterKey = "sk-litellm-foundry-poc"
)

$ErrorActionPreference = "Stop"
$az = if ($env:AZ_CMD) { $env:AZ_CMD } else { "az" }
$bicep = Join-Path $PSScriptRoot "litellm-foundry.bicep"

Write-Host "Reading Foundry account names from main deployment '$MainDeploymentName'..." -ForegroundColor Cyan
$mainOutputs = & $az deployment group show --name $MainDeploymentName --resource-group $ResourceGroup --query properties.outputs | ConvertFrom-Json
$accountNames = @($mainOutputs.foundryAccounts.value | ForEach-Object { $_.name })
if ($accountNames.Count -lt 2) {
    throw "Expected at least 2 Foundry accounts in the main deployment outputs; found $($accountNames.Count)."
}
Write-Host ("Foundry accounts: {0}" -f ($accountNames -join ", "))

Write-Host "Deploying LiteLLM Container App + Foundry Model Gateway connection (a few minutes)..." -ForegroundColor Cyan
& $az deployment group create `
    --name $DeploymentName `
    --resource-group $ResourceGroup `
    --template-file $bicep `
    --parameters `
        foundryAccountNames="$($accountNames | ConvertTo-Json -Compress)" `
        connectionName=$ConnectionName `
        litellmMasterKey=$MasterKey `
    --output none

$outputs = & $az deployment group show --name $DeploymentName --resource-group $ResourceGroup --query properties.outputs | ConvertFrom-Json
$gatewayUrl = $outputs.gatewayUrl.value
$modelDeployment = $outputs.modelDeploymentName.value
$connAccount = $outputs.connectionAccount.value

Write-Host "`nLiteLLM gateway URL : $gatewayUrl" -ForegroundColor Green
Write-Host "Foundry connection  : $ConnectionName (on $connAccount)"
Write-Host "Model deployment    : $modelDeployment"

Write-Host "`nRun the Foundry agent through your gateway:" -ForegroundColor Cyan
Write-Host "  `$env:FOUNDRY_PROJECT_ENDPOINT = '<project endpoint, e.g. https://$connAccount.services.ai.azure.com/api/projects/aigateway-...>'"
Write-Host "  `$env:FOUNDRY_MODEL_DEPLOYMENT_NAME = '$modelDeployment'"
Write-Host "  python ../src/test/agent_foundry_litellm.py"
