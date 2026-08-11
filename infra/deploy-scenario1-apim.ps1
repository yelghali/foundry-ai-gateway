<#
.SYNOPSIS
    Deploy Scenario 1 only: Foundry agent + Toolbox + authenticated BYO APIM.
.DESCRIPTION
    Reuses the APIM/model deployment from deploy.ps1 and the A2A Container App from
    deploy-a2a.ps1. Deploys one client Foundry project with connections for:
      - model inference through APIM (KEY - the only secret in this scenario; see the
        template header for why, and Scenario 2 for the key-free variant),
      - MCP through APIM (project managed identity, Entra token validated by APIM),
      - A2A through APIM (project managed identity), and
      - the Toolbox MCP endpoint (project managed identity).
    Run deploy-a2a-apim.ps1 afterwards to publish the Entra-protected A2A APIs on APIM.
    No LiteLLM resources or parameters are used.
#>
param(
    [string]$ResourceGroup = "lab-foundry-ai-gateway",
    [string]$MainDeploymentName = "backend-pool-load-balancing",
    [string]$A2aDeploymentName = "a2a-dummy-agent",
    [string]$DeploymentName = "client-foundry-sc1"
)

$ErrorActionPreference = "Stop"
$az = if ($env:AZ_CMD) { $env:AZ_CMD } else { "az" }
$template = Join-Path $PSScriptRoot "client-foundry-sc1.bicep"
$configPath = Join-Path $PSScriptRoot "scenario-outputs.json"

$main = & $az deployment group show --name $MainDeploymentName --resource-group $ResourceGroup --query properties.outputs | ConvertFrom-Json
$apimName = $main.apimServiceName.value
$inferencePath = "{0}/openai" -f $main.inferenceAPIPath.value
if (-not $apimName) { throw "Run deploy.ps1 first; APIM deployment outputs were not found." }

$a2a = & $az deployment group show --name $A2aDeploymentName --resource-group $ResourceGroup --query properties.outputs | ConvertFrom-Json
$a2aDirectUrl = $a2a.a2aAgentDirectUrl.value
if (-not $a2aDirectUrl) { throw "Run deploy-a2a.ps1 first; A2A deployment outputs were not found." }

$subscriptionId = & $az account show --query id -o tsv
$enterpriseIds = @($main.foundryAccounts.value | ForEach-Object {
    "/subscriptions/$subscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.CognitiveServices/accounts/$($_.name)"
})
$paramsPath = Join-Path $env:TEMP "foundry_sc1_apim_params.json"
@{
    '$schema' = "https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#"
    contentVersion = "1.0.0.0"
    parameters = @{ enterpriseFoundryIds = @{ value = $enterpriseIds } }
} | ConvertTo-Json -Depth 6 | Set-Content $paramsPath -Encoding utf8

Write-Host "Deploying Scenario 1 (Foundry Toolbox + authenticated BYO APIM)..." -ForegroundColor Cyan
& $az deployment group create `
    --name $DeploymentName `
    --resource-group $ResourceGroup `
    --template-file $template `
    --parameters "@$paramsPath" `
    --parameters apimServiceName=$apimName inferenceApiPath=$inferencePath dummyA2aUrl=$a2aDirectUrl `
    --output none
Remove-Item $paramsPath -ErrorAction SilentlyContinue

$out = & $az deployment group show --name $DeploymentName --resource-group $ResourceGroup --query properties.outputs | ConvertFrom-Json
$endpoint = $out.projectEndpoint.value -replace "\.cognitiveservices\.azure\.com", ".services.ai.azure.com"
$config = if (Test-Path $configPath) { Get-Content $configPath -Raw | ConvertFrom-Json } else { [pscustomobject]@{} }
$values = [ordered]@{
    apimGatewayUrl = "https://$apimName.azure-api.net"
    # Key-protected MCP front door (used by the key-based scenarios/tests).
    mcpApimUrl = $out.mcpApimKeyUrl.value
    sc1ProjectEndpoint = $endpoint
    sc1DriverModel = $out.driverModelDeploymentName.value
    sc1CustomKeyModel = $out.customKeyModelDeploymentName.value
    sc1EntraAudience = $out.entraAudience.value
    sc1McpApimMiUrl = $out.mcpApimMiUrl.value
    sc1McpApimConnId = $out.mcpApimConnectionId.value
    sc1A2aApimUrl = $out.a2aApimUrl.value
    sc1A2aApimConnId = $out.a2aApimConnectionId.value
    sc1ToolboxName = $out.toolboxName.value
    sc1ToolboxMcpUrl = $out.toolboxMcpUrl.value
    sc1ToolboxConnId = $out.toolboxConnectionId.value
}
foreach ($entry in $values.GetEnumerator()) {
    $config | Add-Member -NotePropertyName $entry.Key -NotePropertyValue $entry.Value -Force
}
$config | ConvertTo-Json -Depth 10 | Set-Content $configPath -Encoding utf8

Write-Host "`nScenario 1 is ready." -ForegroundColor Green
Write-Host "  Project : $endpoint"
Write-Host "  MCP     : $($out.mcpApimMiUrl.value) (Entra token, project MI - no key)"
Write-Host "  Toolbox : $($out.toolboxMcpUrl.value) (created by the sample on first run)"
Write-Host "  Next    : ./deploy-a2a-apim.ps1   # publishes the Entra-protected A2A APIs"
Write-Host "  Run     : python ../src/test/scenario1_custom_apim.py"