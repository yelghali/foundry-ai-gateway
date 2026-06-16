<#
.SYNOPSIS
    Deploy the APIM + Azure AI Foundry backend-pool load-balancing lab.
.DESCRIPTION
    Creates a resource group and deploys infra/main.bicep, then prints the
    APIM gateway URL, subscription key, and Foundry endpoints.
.NOTES
    Requires Azure CLI. If az is not on PATH, set $env:AZ_CMD to its full path,
    e.g. "C:\Program Files\Microsoft SDKs\Azure\CLI2\wbin\az.cmd"
#>
param(
    [string]$ResourceGroup = "lab-foundry-ai-gateway",
    [string]$Location = "eastus2",
    [string]$DeploymentName = "backend-pool-load-balancing"
)

$ErrorActionPreference = "Stop"
$az = if ($env:AZ_CMD) { $env:AZ_CMD } else { "az" }
$bicep = Join-Path $PSScriptRoot "main.bicep"

Write-Host "Creating resource group '$ResourceGroup' in '$Location'..." -ForegroundColor Cyan
& $az group create --name $ResourceGroup --location $Location --output none

Write-Host "Deploying Bicep (this provisions APIM v2 + 2 Foundry accounts)..." -ForegroundColor Cyan
& $az deployment group create `
    --name $DeploymentName `
    --resource-group $ResourceGroup `
    --template-file $bicep `
    --output none

Write-Host "`nDeployment outputs:" -ForegroundColor Green
$outputs = & $az deployment group show --name $DeploymentName --resource-group $ResourceGroup --query properties.outputs | ConvertFrom-Json

$gateway = $outputs.apimResourceGatewayURL.value
$key = $outputs.apimSubscriptions.value[0].key

Write-Host "APIM Gateway URL : $gateway"
Write-Host "Subscription key : $key"
Write-Host "`nFoundry backends:"
$outputs.foundryAccounts.value | ForEach-Object {
    Write-Host ("  - {0,-28} {1,-14} priority={2}" -f $_.name, $_.location, $_.priority)
}

Write-Host "`nTest it:" -ForegroundColor Cyan
Write-Host "  `$env:APIM_GATEWAY_URL = '$gateway'"
Write-Host "  `$env:APIM_API_KEY = '<see above>'"
Write-Host "  python ../src/test/test_load_balancing.py"
