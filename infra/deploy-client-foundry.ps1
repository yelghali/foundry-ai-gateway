<#
.SYNOPSIS
    Deploy the dedicated CLIENT Foundry that consumes the enterprise gateways.
.DESCRIPTION
    Deploys infra/client-foundry.bicep on top of an existing main.bicep (+ LiteLLM +
    A2A) deployment. Creates a separate Foundry account (no model deployments) plus the
    connections the client agent uses to reach the enterprise models and tools:
      - apim-gateway        (ApiManagement) -> APIM /inference/openai   "AI Gateway native"
      - litellm-gateway     (ModelGateway)  -> LiteLLM                  "BYO gateway"
      - apim-custom         (CustomKeys)    -> APIM /inference/openai   "custom, gateway URL"
      - mslearn-mcp-apim    (CustomKeys)    -> {apim}/learn-mcp/mcp
      - mslearn-mcp-litellm (CustomKeys)    -> {litellm}/mcp/
      - dummy-a2a-direct    (RemoteA2A)     -> the A2A agent host-root card

    Reads APIM + inference path from the main deployment, the LiteLLM FQDN from the
    LiteLLM deployment, and the A2A agent URL from the A2A deployment.
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

Write-Host "Reading gateway details from existing deployments..." -ForegroundColor Cyan
$mainOutputs = & $az deployment group show --name $MainDeploymentName --resource-group $ResourceGroup --query properties.outputs | ConvertFrom-Json
$apimServiceName = $mainOutputs.apimServiceName.value
$inferenceApiPath = "{0}/openai" -f $mainOutputs.inferenceAPIPath.value
if (-not $apimServiceName) { throw "Could not read apimServiceName from main deployment outputs." }

$litellmOutputs = & $az deployment group show --name $LitellmDeploymentName --resource-group $ResourceGroup --query properties.outputs | ConvertFrom-Json
$litellmFqdn = $litellmOutputs.gatewayFqdn.value
if (-not $litellmFqdn) { throw "Could not read gatewayFqdn from LiteLLM deployment outputs." }

if (-not $DummyA2aUrl) {
    try {
        $a2aOutputs = & $az deployment group show --name $A2aDeploymentName --resource-group $ResourceGroup --query properties.outputs | ConvertFrom-Json
        # Accept a few likely output names for the agent's public URL.
        $DummyA2aUrl = $a2aOutputs.agentPublicUrl.value
        if (-not $DummyA2aUrl) { $DummyA2aUrl = $a2aOutputs.agentUrl.value }
        if (-not $DummyA2aUrl) { $DummyA2aUrl = $a2aOutputs.publicUrl.value }
    } catch { }
}
if (-not $DummyA2aUrl) { throw "Could not determine the A2A agent URL. Pass -DummyA2aUrl explicitly." }

Write-Host ("APIM service     : {0}" -f $apimServiceName)
Write-Host ("Inference path   : {0}" -f $inferenceApiPath)
Write-Host ("LiteLLM FQDN     : {0}" -f $litellmFqdn)
Write-Host ("A2A agent URL    : {0}" -f $DummyA2aUrl)

Write-Host "Deploying the client Foundry + connections..." -ForegroundColor Cyan
& $az deployment group create `
    --name $DeploymentName `
    --resource-group $ResourceGroup `
    --template-file $bicep `
    --parameters `
        apimServiceName=$apimServiceName `
        inferenceApiPath=$inferenceApiPath `
        litellmFqdn=$litellmFqdn `
        litellmMasterKey=$LitellmMasterKey `
        dummyA2aUrl=$DummyA2aUrl `
    --output none

$outputs = & $az deployment group show --name $DeploymentName --resource-group $ResourceGroup --query properties.outputs | ConvertFrom-Json
$clientEndpoint = $outputs.clientProjectEndpoint.value
# The Agent Service uses the *.services.ai.azure.com domain for the project endpoint.
$servicesEndpoint = $clientEndpoint -replace "\.cognitiveservices\.azure\.com", ".services.ai.azure.com"

Write-Host "`nClient project endpoint : $servicesEndpoint" -ForegroundColor Green
Write-Host "Model deployments       : $($outputs.apimModelDeploymentName.value), $($outputs.litellmModelDeploymentName.value), $($outputs.customModelDeploymentName.value)"

Write-Host "`nRun the client agent (model 3 ways + MCP behind APIM/LiteLLM + A2A):" -ForegroundColor Cyan
Write-Host "  `$env:CLIENT_PROJECT_ENDPOINT = '$servicesEndpoint'"
Write-Host "  `$env:MCP_APIM_URL = 'https://$apimServiceName.azure-api.net/learn-mcp/mcp'"
Write-Host "  `$env:MCP_APIM_CONN_ID = '$($outputs.mcpApimConnectionId.value)'"
Write-Host "  `$env:MCP_LITELLM_URL = 'https://$litellmFqdn/mcp/'"
Write-Host "  `$env:MCP_LITELLM_CONN_ID = '$($outputs.mcpLitellmConnectionId.value)'"
Write-Host "  `$env:A2A_DIRECT_URL = '$DummyA2aUrl'"
Write-Host "  `$env:A2A_DIRECT_CONN_ID = '$($outputs.a2aDirectConnectionId.value)'"
Write-Host "  `$env:KEEP_AGENT = '1'"
Write-Host "  python ../src/test/agent_foundry_client.py"
