<#
.SYNOPSIS
    Deploy the APIM + Azure AI Foundry backend-pool load-balancing lab.
.DESCRIPTION
    Creates a resource group and deploys the keyless enterprise APIM model gateway,
    two Foundry model regions, and the Microsoft Learn MCP backend.
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
if ($LASTEXITCODE -ne 0) { throw "Resource group creation failed." }

Write-Host "Deploying Bicep (this provisions APIM v2 + 2 Foundry accounts)..." -ForegroundColor Cyan
& $az deployment group create `
    --name $DeploymentName `
    --resource-group $ResourceGroup `
    --template-file $bicep `
    --output none
if ($LASTEXITCODE -ne 0) { throw "Core APIM and Foundry deployment failed." }

Write-Host "`nDeployment outputs:" -ForegroundColor Green
$outputs = & $az deployment group show --name $DeploymentName --resource-group $ResourceGroup --query properties.outputs | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or -not $outputs.apimServiceName.value) {
    throw "Could not read core deployment outputs."
}
$requiredOutputs = @(
    "apimServiceId",
    "apimServiceName",
    "apimResourceGatewayURL",
    "apimLogAnalyticsWorkspaceId",
    "apimLogAnalyticsWorkspaceName",
    "apimDiagnosticSettingsName"
)
foreach ($name in $requiredOutputs) {
    if (-not $outputs.$name.value) {
        throw "Core deployment output '$name' is missing."
    }
}

$gateway = $outputs.apimResourceGatewayURL.value
Write-Host "APIM Gateway URL : $gateway"
Write-Host "Model API        : $gateway/$($outputs.miInferenceAPIPath.value) (Microsoft Entra ID)"
Write-Host "APIM logs        : $($outputs.apimLogAnalyticsWorkspaceName.value)"
Write-Host "`nFoundry backends:"
$outputs.foundryAccounts.value | ForEach-Object {
    Write-Host ("  - {0,-28} {1,-14} priority={2}" -f $_.name, $_.location, $_.priority)
}

$outputsFile = Join-Path $PSScriptRoot "scenario-outputs.json"
$config = if (Test-Path $outputsFile) { Get-Content $outputsFile -Raw -Encoding UTF8 | ConvertFrom-Json } else { [pscustomobject]@{} }
$apimServiceId = $outputs.apimServiceId.value
$hasExistingConfig = @($config.PSObject.Properties).Count -gt 0
$manifestMatchesEnvironment = $config.resourceGroup -eq $ResourceGroup -and $config.apimServiceId -eq $apimServiceId
if ($hasExistingConfig -and -not $manifestMatchesEnvironment) {
    $config = [pscustomobject]@{}
}
$values = [ordered]@{
    resourceGroup = $ResourceGroup
    apimServiceId = $apimServiceId
    apimServiceName = $outputs.apimServiceName.value
    apimGatewayUrl = $gateway
    apimLogAnalyticsWorkspaceId = $outputs.apimLogAnalyticsWorkspaceId.value
    apimLogAnalyticsWorkspaceName = $outputs.apimLogAnalyticsWorkspaceName.value
    apimDiagnosticSettingsName = $outputs.apimDiagnosticSettingsName.value
}
foreach ($entry in $values.GetEnumerator()) {
    $config | Add-Member -NotePropertyName $entry.Key -NotePropertyValue $entry.Value -Force
}
$tempOutputsFile = "$outputsFile.tmp"
$config | ConvertTo-Json -Depth 10 | Set-Content $tempOutputsFile -Encoding utf8
Move-Item $tempOutputsFile $outputsFile -Force

Write-Host "`nNext:" -ForegroundColor Cyan
Write-Host "  ./deploy-foundry-consumers.ps1"
Write-Host "  ./deploy-two-consumer-apim.ps1"
