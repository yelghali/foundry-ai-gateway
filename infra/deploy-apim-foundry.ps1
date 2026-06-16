<#
.SYNOPSIS
    Register your existing APIM gateway as an Azure AI Foundry "API Management" connection.
.DESCRIPTION
    Deploys infra/apim-foundry.bicep on top of an existing main.bicep deployment:
      - A Foundry connection (category: ApiManagement) on the Foundry account that
        points Foundry Agent Service at the APIM inference API (Parts 1-3).
    Reads the APIM service name, inference API path and the first Foundry account
    name from the main deployment outputs.

    This is the APIM variant of Part 5 (the LiteLLM variant is deploy-litellm-foundry.ps1).
.NOTES
    Requires Azure CLI. If az is not on PATH, set $env:AZ_CMD to its full path,
    e.g. "C:\Program Files\Microsoft SDKs\Azure\CLI2\wbin\az.cmd"
#>
param(
    [string]$ResourceGroup = "lab-foundry-ai-gateway",
    [string]$MainDeploymentName = "backend-pool-load-balancing",
    [string]$DeploymentName = "apim-foundry-gateway",
    [string]$ConnectionName = "apim-gateway",
    [string]$ApimSubscriptionName = "subscription1"
)

$ErrorActionPreference = "Stop"
$az = if ($env:AZ_CMD) { $env:AZ_CMD } else { "az" }
$bicep = Join-Path $PSScriptRoot "apim-foundry.bicep"

Write-Host "Reading APIM + Foundry details from main deployment '$MainDeploymentName'..." -ForegroundColor Cyan
$mainOutputs = & $az deployment group show --name $MainDeploymentName --resource-group $ResourceGroup --query properties.outputs | ConvertFrom-Json
$apimServiceName = $mainOutputs.apimServiceName.value
$inferenceApiPath = "{0}/openai" -f $mainOutputs.inferenceAPIPath.value
$accountNames = @($mainOutputs.foundryAccounts.value | ForEach-Object { $_.name })
if (-not $apimServiceName) { throw "Could not read apimServiceName from main deployment outputs." }
if ($accountNames.Count -lt 1) { throw "Could not read Foundry account names from main deployment outputs." }
$connectionAccount = $accountNames[0]
Write-Host ("APIM service     : {0}" -f $apimServiceName)
Write-Host ("Inference path   : {0}" -f $inferenceApiPath)
Write-Host ("Connection host  : {0}" -f $connectionAccount)

Write-Host "Creating the Foundry API Management connection..." -ForegroundColor Cyan
& $az deployment group create `
    --name $DeploymentName `
    --resource-group $ResourceGroup `
    --template-file $bicep `
    --parameters `
        apimServiceName=$apimServiceName `
        apimSubscriptionName=$ApimSubscriptionName `
        connectionAccountName=$connectionAccount `
        inferenceApiPath=$inferenceApiPath `
        connectionName=$ConnectionName `
    --output none

$outputs = & $az deployment group show --name $DeploymentName --resource-group $ResourceGroup --query properties.outputs | ConvertFrom-Json
$gatewayUrl = $outputs.gatewayUrl.value
$modelDeployment = $outputs.modelDeploymentName.value
$connAccount = $outputs.connectionAccount.value

Write-Host "`nAPIM gateway URL   : $gatewayUrl" -ForegroundColor Green
Write-Host "Foundry connection : $ConnectionName (on $connAccount)"
Write-Host "Model deployment   : $modelDeployment"

Write-Host "`nRun the Foundry agent through your APIM gateway:" -ForegroundColor Cyan
Write-Host "  `$env:FOUNDRY_PROJECT_ENDPOINT = '<project endpoint, e.g. https://$connAccount.services.ai.azure.com/api/projects/aigateway-...>'"
Write-Host "  `$env:FOUNDRY_MODEL_DEPLOYMENT_NAME = '$modelDeployment'"
Write-Host "  python ../src/test/agent_foundry_apim.py"
