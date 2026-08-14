<#
.SYNOPSIS
    Deploy the Toolbox publisher and the single Foundry-hosted consumer app.
.DESCRIPTION
    Reuses deterministic legacy account names for in-place upgrades. The app project's
    ApiManagement model connection is created only when absent because Foundry connections
    are ownership-bound and cannot always be updated by a later ARM deployment.
#>
param(
    [string]$ResourceGroup = "lab-foundry-ai-gateway",
    [string]$MainDeploymentName = "backend-pool-load-balancing",
    [string]$DeploymentName = "foundry-consumers",
    [string]$ToolboxProjectName = "aigateway-sc1",
    [string]$AppProjectName = "aigateway-sc2",
    [string]$InboundAudience = "https://cognitiveservices.azure.com"
)

$ErrorActionPreference = "Stop"
$az = if ($env:AZ_CMD) { $env:AZ_CMD } else { "az" }
$template = Join-Path $PSScriptRoot "foundry-consumers.bicep"
$outputsFile = Join-Path $PSScriptRoot "scenario-outputs.json"

$main = & $az deployment group show --name $MainDeploymentName --resource-group $ResourceGroup --query properties.outputs | ConvertFrom-Json
$apimName = $main.apimServiceName.value
if (-not $apimName) { throw "Run deploy.ps1 before deploy-foundry-consumers.ps1." }

$suffix = $apimName -replace '^apim-', ''
$toolboxAccount = "client-foundry-sc1-$suffix"
$appAccount = "client-foundry-sc2-$suffix"
$subscriptionId = (& $az account show --query id -o tsv).Trim()
$modelConnectionId = "/subscriptions/$subscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.CognitiveServices/accounts/$appAccount/projects/$AppProjectName/connections/apim-gateway-mi"
& $az resource show --ids $modelConnectionId --api-version 2025-04-01-preview --only-show-errors --output none 2>$null
$createModelConnection = $LASTEXITCODE -ne 0

$paramsPath = Join-Path $env:TEMP "foundry_consumers_params.json"
@{
    '$schema' = "https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#"
    contentVersion = "1.0.0.0"
    parameters = @{
        apimServiceName = @{ value = $apimName }
        toolboxPublisherAccountName = @{ value = $toolboxAccount }
        toolboxPublisherProjectName = @{ value = $ToolboxProjectName }
        appFoundryAccountName = @{ value = $appAccount }
        appFoundryProjectName = @{ value = $AppProjectName }
        createModelConnection = @{ value = $createModelConnection }
        inboundAudience = @{ value = $InboundAudience }
    }
} | ConvertTo-Json -Depth 8 | Set-Content $paramsPath -Encoding utf8

Write-Host "Deploying the Toolbox publisher and Foundry app consumer..." -ForegroundColor Cyan
& $az deployment group create `
    --name $DeploymentName `
    --resource-group $ResourceGroup `
    --template-file $template `
    --parameters "@$paramsPath" `
    --output none
$exitCode = $LASTEXITCODE
Remove-Item $paramsPath -ErrorAction SilentlyContinue
if ($exitCode -ne 0) { throw "Foundry consumer deployment failed." }

$out = & $az deployment group show --name $DeploymentName --resource-group $ResourceGroup --query properties.outputs | ConvertFrom-Json
$config = if (Test-Path $outputsFile) { Get-Content $outputsFile -Raw -Encoding UTF8 | ConvertFrom-Json } else { [pscustomobject]@{} }
$values = [ordered]@{
    toolboxPublisherAccountName = $out.toolboxPublisherAccountName.value
    toolboxProjectEndpoint = $out.toolboxProjectEndpoint.value
    appFoundryAccountName = $out.appFoundryAccountName.value
    appProjectEndpoint = $out.appProjectEndpoint.value
    appDriverModel = $out.appDriverModel.value
    appModel = $out.appModel.value
    appModelConnectionId = $out.appModelConnectionId.value
}
foreach ($entry in $values.GetEnumerator()) {
    $config | Add-Member -NotePropertyName $entry.Key -NotePropertyValue $entry.Value -Force
}
$config | ConvertTo-Json -Depth 10 | Set-Content $outputsFile -Encoding utf8

Write-Host "`nFoundry publisher and consumer are ready." -ForegroundColor Green
Write-Host "  Toolbox project : $($out.toolboxProjectEndpoint.value)"
Write-Host "  App project     : $($out.appProjectEndpoint.value)"
Write-Host "  APIM model      : $($out.appModel.value)"