<#
.SYNOPSIS
    Deploy the THREE dedicated CLIENT Foundry accounts that consume the enterprise gateways.
.DESCRIPTION
    Deploys the THREE per-scenario bicep files (client-foundry-sc1/sc2/sc3.bicep) as three
    independent deployments on top of an existing main.bicep (+ LiteLLM + A2A) deployment.
    The consumer side is split into one Foundry account per gateway pattern, because the
    native AI Gateway integration is configured at the Foundry *resource* level:

      client-foundry-sc1  CUSTOM (APIM)        subscription-key custom connection
      client-foundry-sc2  AI GATEWAY NATIVE    Foundry ApiManagement connection (MI-first, key fallback)
      client-foundry-sc3  AI GATEWAY BYO       LiteLLM ModelGateway connection

    After the Bicep deploy, this script writes a secret-free infra/scenario-outputs.json that
    the scenario scripts auto-load, so a replay is just "deploy, then run the scripts".

    Reads APIM + inference path + enterprise Foundry names from the main deployment, the
    LiteLLM FQDN from the LiteLLM deployment, and the A2A agent URL from the A2A deployment.
.NOTES
    Requires Azure CLI. If az is not on PATH, set $env:AZ_CMD to its full path,
    e.g. "C:\Program Files\Microsoft SDKs\Azure\CLI2\wbin\az.cmd"
#>
param(
    [string]$ResourceGroup = "lab-foundry-ai-gateway",
    [string]$MainDeploymentName = "backend-pool-load-balancing",
    [string]$LitellmDeploymentName = "litellm-foundry-gateway",
    [string]$A2aDeploymentName = "a2a-dummy-agent",
    [Parameter(Mandatory = $true)][string]$LitellmMasterKey,
    [string]$DummyA2aUrl = ""
)

$ErrorActionPreference = "Stop"
$az = if ($env:AZ_CMD) { $env:AZ_CMD } else { "az" }
$sc1Bicep = Join-Path $PSScriptRoot "client-foundry-sc1.bicep"
$sc2Bicep = Join-Path $PSScriptRoot "client-foundry-sc2.bicep"
$sc3Bicep = Join-Path $PSScriptRoot "client-foundry-sc3.bicep"
$inferenceApiVersion = "2024-10-21"

function To-ServicesEndpoint([string]$endpoint) {
    return ($endpoint -replace "\.cognitiveservices\.azure\.com", ".services.ai.azure.com")
}

Write-Host "Reading gateway details from existing deployments..." -ForegroundColor Cyan
$mainOutputs = & $az deployment group show --name $MainDeploymentName --resource-group $ResourceGroup --query properties.outputs | ConvertFrom-Json
$apimServiceName = $mainOutputs.apimServiceName.value
$inferenceApiPath = "{0}/openai" -f $mainOutputs.inferenceAPIPath.value
if (-not $apimServiceName) { throw "Could not read apimServiceName from main deployment outputs." }

# Enterprise Foundry account names -> resource IDs (grant each client account MI data-plane access).
$enterpriseNames = @()
if ($mainOutputs.foundryAccounts) {
    $enterpriseNames = @($mainOutputs.foundryAccounts.value | ForEach-Object { $_.name })
}
$subId = (& $az account show --query id -o tsv)
$enterpriseIds = @($enterpriseNames | ForEach-Object { "/subscriptions/$subId/resourceGroups/$ResourceGroup/providers/Microsoft.CognitiveServices/accounts/$_" })
# Pass the array via a parameters file (PowerShell mangles inline JSON quotes for native args).
$paramsFile = Join-Path $env:TEMP "client_foundry_params.json"
$paramsObj = [ordered]@{
    '$schema'      = "https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#"
    contentVersion = "1.0.0.0"
    parameters     = [ordered]@{
        enterpriseFoundryIds = @{ value = @($enterpriseIds) }
    }
}
$paramsObj | ConvertTo-Json -Depth 6 | Set-Content -Path $paramsFile -Encoding utf8

$litellmOutputs = & $az deployment group show --name $LitellmDeploymentName --resource-group $ResourceGroup --query properties.outputs | ConvertFrom-Json
$litellmFqdn = $litellmOutputs.gatewayFqdn.value
if (-not $litellmFqdn) { throw "Could not read gatewayFqdn from LiteLLM deployment outputs." }

if (-not $DummyA2aUrl) {
    try {
        $a2aOutputs = & $az deployment group show --name $A2aDeploymentName --resource-group $ResourceGroup --query properties.outputs | ConvertFrom-Json
        $DummyA2aUrl = $a2aOutputs.agentPublicUrl.value
        if (-not $DummyA2aUrl) { $DummyA2aUrl = $a2aOutputs.agentUrl.value }
        if (-not $DummyA2aUrl) { $DummyA2aUrl = $a2aOutputs.publicUrl.value }
    } catch { }
}
if (-not $DummyA2aUrl) { throw "Could not determine the A2A agent URL. Pass -DummyA2aUrl explicitly." }

Write-Host ("APIM service       : {0}" -f $apimServiceName)
Write-Host ("Inference path     : {0}" -f $inferenceApiPath)
Write-Host ("Enterprise Foundry : {0}" -f ($enterpriseNames -join ", "))
Write-Host ("LiteLLM FQDN       : {0}" -f $litellmFqdn)
Write-Host ("A2A agent URL      : {0}" -f $DummyA2aUrl)

Write-Host "Deploying Scenario 1 (custom APIM) client Foundry..." -ForegroundColor Cyan
& $az deployment group create `
    --name "client-foundry-sc1" `
    --resource-group $ResourceGroup `
    --template-file $sc1Bicep `
    --parameters "@$paramsFile" `
    --parameters `
        apimServiceName=$apimServiceName `
        inferenceApiPath=$inferenceApiPath `
        inferenceApiVersion=$inferenceApiVersion `
        dummyA2aUrl=$DummyA2aUrl `
    --output none

Write-Host "Deploying Scenario 2 (native APIM) client Foundry..." -ForegroundColor Cyan
& $az deployment group create `
    --name "client-foundry-sc2" `
    --resource-group $ResourceGroup `
    --template-file $sc2Bicep `
    --parameters "@$paramsFile" `
    --parameters `
        apimServiceName=$apimServiceName `
        inferenceApiPath=$inferenceApiPath `
        inferenceApiVersion=$inferenceApiVersion `
        dummyA2aUrl=$DummyA2aUrl `
    --output none

Write-Host "Deploying Scenario 3 (BYO LiteLLM) client Foundry..." -ForegroundColor Cyan
& $az deployment group create `
    --name "client-foundry-sc3" `
    --resource-group $ResourceGroup `
    --template-file $sc3Bicep `
    --parameters "@$paramsFile" `
    --parameters `
        litellmFqdn=$litellmFqdn `
        litellmMasterKey=$LitellmMasterKey `
        dummyA2aUrl=$DummyA2aUrl `
    --output none
Remove-Item $paramsFile -ErrorAction SilentlyContinue

$sc1Out = & $az deployment group show --name "client-foundry-sc1" --resource-group $ResourceGroup --query properties.outputs | ConvertFrom-Json
$sc2Out = & $az deployment group show --name "client-foundry-sc2" --resource-group $ResourceGroup --query properties.outputs | ConvertFrom-Json
$sc3Out = & $az deployment group show --name "client-foundry-sc3" --resource-group $ResourceGroup --query properties.outputs | ConvertFrom-Json

$apimBase = "https://$apimServiceName.azure-api.net"
$mcpApimUrl = "$apimBase/learn-mcp/mcp"
$mcpLitellmUrl = "https://$litellmFqdn/mcp/"

$sc1Endpoint = To-ServicesEndpoint $sc1Out.projectEndpoint.value
$sc2Endpoint = To-ServicesEndpoint $sc2Out.projectEndpoint.value
$sc3Endpoint = To-ServicesEndpoint $sc3Out.projectEndpoint.value

# ---- Write the secret-free config the scenario scripts auto-load.
$config = [ordered]@{
    apimGatewayUrl       = $apimBase
    mcpApimUrl           = $mcpApimUrl
    a2aDirectUrl         = $DummyA2aUrl

    sc1ProjectEndpoint   = $sc1Endpoint
    sc1DriverModel       = $sc1Out.driverModelDeploymentName.value
    sc1CustomKeyModel    = $sc1Out.customKeyModelDeploymentName.value
    sc1McpApimConnId     = $sc1Out.mcpApimConnectionId.value
    sc1A2aConnId         = $sc1Out.a2aDirectConnectionId.value

    sc2ProjectEndpoint   = $sc2Endpoint
    sc2DriverModel       = $sc2Out.driverModelDeploymentName.value
    sc2MiModel           = $sc2Out.apimMiModelDeploymentName.value
    sc2Model             = $sc2Out.apimModelDeploymentName.value
    sc2McpApimConnId     = $sc2Out.mcpApimConnectionId.value
    sc2A2aConnId         = $sc2Out.a2aDirectConnectionId.value

    sc3ProjectEndpoint   = $sc3Endpoint
    sc3DriverModel       = $sc3Out.driverModelDeploymentName.value
    sc3Model             = $sc3Out.litellmModelDeploymentName.value
    sc3McpLitellmUrl     = $mcpLitellmUrl
    sc3McpLitellmConnId  = $sc3Out.mcpLitellmConnectionId.value
    sc3A2aConnId         = $sc3Out.a2aDirectConnectionId.value
}
$configPath = Join-Path $PSScriptRoot "scenario-outputs.json"
$config | ConvertTo-Json -Depth 6 | Set-Content -Path $configPath -Encoding utf8
Write-Host "`nWrote $configPath (the scenario scripts auto-load it)." -ForegroundColor Green

Write-Host "`n== Three client Foundry accounts ==" -ForegroundColor Green
Write-Host ("  Scenario 1 (custom APIM)   : {0}" -f $sc1Endpoint)
Write-Host ("  Scenario 2 (native APIM)   : {0}" -f $sc2Endpoint)
Write-Host ("  Scenario 3 (BYO LiteLLM)   : {0}" -f $sc3Endpoint)

Write-Host "`nReplay the lab (each scenario does model -> tool -> A2A):" -ForegroundColor Cyan
Write-Host "  # Scenario 0 = local MAF agents (no Foundry) — needs only the APIM passthrough APIs:"
Write-Host "  `$env:APIM_GATEWAY_URL = '$apimBase'"
Write-Host "  `$env:APIM_API_KEY = '<APIM subscription key>'"
Write-Host "  python ../src/test/scenario0_local_apim.py"
Write-Host "  # Scenarios 1-3 read infra/scenario-outputs.json automatically:"
Write-Host "  # agents persist by default (visible in Build > Agents); set KEEP_AGENT=0 to clean up"
Write-Host "  python ../src/test/scenario1_custom_apim.py"
Write-Host "  python ../src/test/scenario2_aigateway_native.py"
Write-Host "  python ../src/test/scenario3_aigateway_litellm.py"
