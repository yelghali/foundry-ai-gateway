<#
.SYNOPSIS
    Deploy only the Scenario 2 Foundry consumer for the APIM-focused workshop path.
.DESCRIPTION
    Reuses the enterprise APIM/model/MCP deployment and dummy A2A deployment. Creates the
    Scenario 2 client Foundry account with its managed-identity ApiManagement model connection.
    LiteLLM is not read, deployed, or required.
#>
param(
    [string]$ResourceGroup = "lab-foundry-ai-gateway",
    [string]$MainDeploymentName = "backend-pool-load-balancing",
    [string]$A2aDeploymentName = "a2a-dummy-agent",
    [string]$DeploymentName = "client-foundry-sc2"
)

$ErrorActionPreference = "Stop"
$az = if ($env:AZ_CMD) { $env:AZ_CMD } else { "az" }
$template = Join-Path $PSScriptRoot "client-foundry-sc2.bicep"
$configPath = Join-Path $PSScriptRoot "scenario-outputs.json"

function To-ServicesEndpoint([string]$endpoint) {
    return ($endpoint -replace "\.cognitiveservices\.azure\.com", ".services.ai.azure.com")
}

$main = & $az deployment group show --name $MainDeploymentName --resource-group $ResourceGroup --query properties.outputs | ConvertFrom-Json
$a2a = & $az deployment group show --name $A2aDeploymentName --resource-group $ResourceGroup --query properties.outputs | ConvertFrom-Json
$apimName = $main.apimServiceName.value
$inferencePath = "{0}/openai" -f $main.inferenceAPIPath.value
$miInferencePath = "{0}/openai" -f $main.miInferenceAPIPath.value
$dummyA2aUrl = $a2a.a2aAgentDirectUrl.value
if (-not $apimName -or -not $dummyA2aUrl) {
    throw "Run deploy.ps1 and deploy-a2a.ps1 before deploy-scenario2-apim.ps1."
}

$subscriptionId = & $az account show --query id -o tsv
$enterpriseIds = @($main.foundryAccounts.value | ForEach-Object {
    "/subscriptions/$subscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.CognitiveServices/accounts/$($_.name)"
})
$paramsPath = Join-Path $env:TEMP "foundry_sc2_apim_params.json"
@{
    '$schema' = "https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#"
    contentVersion = "1.0.0.0"
    parameters = @{
        apimServiceName = @{ value = $apimName }
        inferenceApiPath = @{ value = $inferencePath }
        miInferenceApiPath = @{ value = $miInferencePath }
        inferenceApiVersion = @{ value = "2024-10-21" }
        dummyA2aUrl = @{ value = $dummyA2aUrl }
        enterpriseFoundryIds = @{ value = $enterpriseIds }
    }
} | ConvertTo-Json -Depth 8 | Set-Content $paramsPath -Encoding utf8

Write-Host "Deploying Scenario 2 APIM consumer (no LiteLLM)..." -ForegroundColor Cyan
& $az deployment group create `
    --name $DeploymentName `
    --resource-group $ResourceGroup `
    --template-file $template `
    --parameters "@$paramsPath" `
    --output none
$exitCode = $LASTEXITCODE
Remove-Item $paramsPath -ErrorAction SilentlyContinue
if ($exitCode -ne 0) { throw "Scenario 2 deployment failed." }

$out = & $az deployment group show --name $DeploymentName --resource-group $ResourceGroup --query properties.outputs | ConvertFrom-Json
$endpoint = To-ServicesEndpoint $out.projectEndpoint.value
$config = if (Test-Path $configPath) { Get-Content $configPath -Raw -Encoding UTF8 | ConvertFrom-Json } else { [pscustomobject]@{} }
$values = [ordered]@{
    apimGatewayUrl = "https://$apimName.azure-api.net"
    mcpApimUrl = "https://$apimName.azure-api.net/learn-mcp/mcp"
    a2aDirectUrl = $dummyA2aUrl
    sc2ProjectEndpoint = $endpoint
    sc2DriverModel = $out.driverModelDeploymentName.value
    sc2MiModel = $out.apimMiModelDeploymentName.value
    sc2Model = $out.apimModelDeploymentName.value
    sc2McpApimConnId = $out.mcpApimConnectionId.value
    sc2A2aConnId = $out.a2aDirectConnectionId.value
}
foreach ($entry in $values.GetEnumerator()) {
    $config | Add-Member -NotePropertyName $entry.Key -NotePropertyValue $entry.Value -Force
}
$config | ConvertTo-Json -Depth 10 | Set-Content $configPath -Encoding utf8

Write-Host "`nScenario 2 is ready without LiteLLM." -ForegroundColor Green
Write-Host "  Project : $endpoint"
Write-Host "  Run     : python ../src/test/scenario2_aigateway_native.py"
Write-Host "  Next    : ./deploy-enterprise-foundry-agent-apim.ps1"
