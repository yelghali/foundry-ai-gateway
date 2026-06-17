<#
.SYNOPSIS
    Deploy the THREE dedicated CLIENT Foundry accounts that consume the enterprise gateways.
.DESCRIPTION
    Deploys infra/client-foundry.bicep on top of an existing main.bicep (+ LiteLLM + A2A)
    deployment. The consumer side is split into one Foundry account per gateway pattern,
    because the native AI Gateway integration is configured at the Foundry *resource* level:

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
    [string]$DeploymentName = "client-foundry",
    [Parameter(Mandatory = $true)][string]$LitellmMasterKey,
    [string]$DummyA2aUrl = ""
)

$ErrorActionPreference = "Stop"
$az = if ($env:AZ_CMD) { $env:AZ_CMD } else { "az" }
$bicep = Join-Path $PSScriptRoot "client-foundry.bicep"
$inferenceApiVersion = "2024-10-21"

function To-ServicesEndpoint([string]$endpoint) {
    return ($endpoint -replace "\.cognitiveservices\.azure\.com", ".services.ai.azure.com")
}

Write-Host "Reading gateway details from existing deployments..." -ForegroundColor Cyan
$mainOutputs = & $az deployment group show --name $MainDeploymentName --resource-group $ResourceGroup --query properties.outputs | ConvertFrom-Json
$apimServiceName = $mainOutputs.apimServiceName.value
$inferenceApiPath = "{0}/openai" -f $mainOutputs.inferenceAPIPath.value
if (-not $apimServiceName) { throw "Could not read apimServiceName from main deployment outputs." }

# Enterprise Foundry account names — used to grant the Scenario 1 MI data-plane access.
$enterpriseNames = @()
if ($mainOutputs.foundryAccounts) {
    $enterpriseNames = @($mainOutputs.foundryAccounts.value | ForEach-Object { $_.name })
}
# Pass the array via a parameters file (PowerShell mangles inline JSON quotes for native args).
$paramsFile = Join-Path $env:TEMP "client_foundry_params.json"
$paramsObj = [ordered]@{
    '$schema'      = "https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#"
    contentVersion = "1.0.0.0"
    parameters     = [ordered]@{
        enterpriseFoundryNames = @{ value = @($enterpriseNames) }
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

Write-Host "Deploying the three client Foundry accounts + connections..." -ForegroundColor Cyan
& $az deployment group create `
    --name $DeploymentName `
    --resource-group $ResourceGroup `
    --template-file $bicep `
    --parameters "@$paramsFile" `
    --parameters `
        apimServiceName=$apimServiceName `
        inferenceApiPath=$inferenceApiPath `
        inferenceApiVersion=$inferenceApiVersion `
        litellmFqdn=$litellmFqdn `
        litellmMasterKey=$LitellmMasterKey `
        dummyA2aUrl=$DummyA2aUrl `
    --output none
Remove-Item $paramsFile -ErrorAction SilentlyContinue

$outputs = & $az deployment group show --name $DeploymentName --resource-group $ResourceGroup --query properties.outputs | ConvertFrom-Json

$apimBase = "https://$apimServiceName.azure-api.net"
$mcpApimUrl = "$apimBase/learn-mcp/mcp"
$mcpLitellmUrl = "https://$litellmFqdn/mcp/"

$sc1Endpoint = To-ServicesEndpoint $outputs.sc1ProjectEndpoint.value
$sc2Endpoint = To-ServicesEndpoint $outputs.sc2ProjectEndpoint.value
$sc3Endpoint = To-ServicesEndpoint $outputs.sc3ProjectEndpoint.value

# ---- Write the secret-free config the scenario scripts auto-load.
$config = [ordered]@{
    apimGatewayUrl       = $apimBase
    mcpApimUrl           = $mcpApimUrl
    a2aDirectUrl         = $DummyA2aUrl

    sc1ProjectEndpoint   = $sc1Endpoint
    sc1DriverModel       = $outputs.sc1DriverModelDeploymentName.value
    sc1CustomKeyModel    = $outputs.sc1CustomKeyModelDeploymentName.value
    sc1McpApimConnId     = $outputs.sc1McpApimConnectionId.value
    sc1A2aConnId         = $outputs.sc1A2aDirectConnectionId.value

    sc2ProjectEndpoint   = $sc2Endpoint
    sc2DriverModel       = $outputs.sc2DriverModelDeploymentName.value
    sc2MiModel           = $outputs.sc2ApimMiModelDeploymentName.value
    sc2Model             = $outputs.sc2ApimModelDeploymentName.value
    sc2McpApimConnId     = $outputs.sc2McpApimConnectionId.value
    sc2A2aConnId         = $outputs.sc2A2aDirectConnectionId.value

    sc3ProjectEndpoint   = $sc3Endpoint
    sc3DriverModel       = $outputs.sc3DriverModelDeploymentName.value
    sc3Model             = $outputs.sc3LitellmModelDeploymentName.value
    sc3McpLitellmUrl     = $mcpLitellmUrl
    sc3McpLitellmConnId  = $outputs.sc3McpLitellmConnectionId.value
    sc3A2aConnId         = $outputs.sc3A2aDirectConnectionId.value
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
Write-Host "  `$env:KEEP_AGENT = '1'   # optional: leave agents in the portal (Build > Agents)"
Write-Host "  python ../src/test/scenario1_custom_apim.py"
Write-Host "  python ../src/test/scenario2_aigateway_native.py"
Write-Host "  python ../src/test/scenario3_aigateway_litellm.py"
