<#
.SYNOPSIS
    Publish an enterprise Foundry agent through APIM and configure two keyless consumers.
.DESCRIPTION
    1. Creates/updates a prompt agent in the first enterprise Foundry project and enables its
       incoming A2A endpoint.
    2. Exposes that endpoint at /enterprise-agents/enterprise-specialist on APIM.
    3. Allows the local signed-in developer and the Scenario 2 project MI to call APIM.
    4. Grants APIM only Foundry Agent Consumer on the enterprise project.
    5. Creates a ProjectManagedIdentity RemoteA2A connection in the Scenario 2 project.

    No APIM subscription key, Foundry key, or connection secret is created or stored.
#>
param(
    [string]$ResourceGroup = "lab-foundry-ai-gateway",
    [string]$MainDeploymentName = "backend-pool-load-balancing",
    [string]$ConsumerDeploymentName = "client-foundry-sc2",
    [string]$DeploymentName = "enterprise-foundry-agent-apim",
    [string]$EnterpriseProjectName = "aigateway-foundry1",
    [string]$EnterpriseAgentName = "enterprise-specialist",
    [string]$ConsumerProjectName = "aigateway-sc2",
    [string]$ApiPath = "enterprise-agents/enterprise-specialist",
    [string]$InboundAudience = "https://cognitiveservices.azure.com",
    [string]$LocalCallerObjectId = ""
)

$ErrorActionPreference = "Stop"
$az = if ($env:AZ_CMD) { $env:AZ_CMD } else { "az" }
$template = Join-Path $PSScriptRoot "enterprise-foundry-agent-apim.bicep"
$setupScript = Join-Path (Split-Path $PSScriptRoot -Parent) "src/test/setup_enterprise_foundry_agent.py"
$outputsFile = Join-Path $PSScriptRoot "scenario-outputs.json"
$venvPython = Join-Path (Split-Path $PSScriptRoot -Parent) "src/test/.venv/Scripts/python.exe"
$python = if (Test-Path $venvPython) { $venvPython } else { "python" }

# The Python samples authenticate with DefaultAzureCredential, which shells out to `az`.
# When AZ_CMD points at a CLI that is not on PATH, make it discoverable for child processes.
if ($env:AZ_CMD) {
    $azDir = Split-Path $env:AZ_CMD -Parent
    if ($azDir -and ($env:PATH -notlike "*$azDir*")) {
        $env:PATH = "$azDir;$env:PATH"
    }
}

function To-ServicesEndpoint([string]$endpoint) {
    return (($endpoint -replace "\.cognitiveservices\.azure\.com", ".services.ai.azure.com").TrimEnd('/'))
}

Write-Host "Reading enterprise APIM and Foundry outputs..." -ForegroundColor Cyan
$main = & $az deployment group show --name $MainDeploymentName --resource-group $ResourceGroup --query properties.outputs | ConvertFrom-Json
$consumer = & $az deployment group show --name $ConsumerDeploymentName --resource-group $ResourceGroup --query properties.outputs | ConvertFrom-Json
$apimName = $main.apimServiceName.value
$enterprise = @($main.foundryAccounts.value)[0]
$enterpriseAccountName = $enterprise.name
$enterpriseProjectEndpoint = "$(To-ServicesEndpoint $enterprise.endpoint)/api/projects/$EnterpriseProjectName"
$consumerAccountName = $consumer.accountName.value

if (-not $apimName -or -not $enterpriseAccountName -or -not $consumerAccountName) {
    throw "Run deploy.ps1 and deploy-client-foundry.ps1 before this extension."
}

if (-not $LocalCallerObjectId) {
    try {
        $LocalCallerObjectId = (& $az ad signed-in-user show --query id -o tsv).Trim()
    } catch { }
}
if (-not $LocalCallerObjectId) {
    throw "Could not resolve the local caller object ID. Pass -LocalCallerObjectId explicitly."
}

Write-Host "Creating the enterprise Foundry agent and enabling incoming A2A..." -ForegroundColor Cyan
& $python $setupScript `
    --project-endpoint $enterpriseProjectEndpoint `
    --agent-name $EnterpriseAgentName `
    --model "gpt-4o-mini"
if ($LASTEXITCODE -ne 0) { throw "Enterprise agent setup failed." }

$paramsPath = Join-Path $env:TEMP "enterprise_foundry_agent_apim_params.json"
@{
    '$schema' = "https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#"
    contentVersion = "1.0.0.0"
    parameters = @{
        apimServiceName = @{ value = $apimName }
        enterpriseFoundryAccountName = @{ value = $enterpriseAccountName }
        enterpriseFoundryProjectName = @{ value = $EnterpriseProjectName }
        enterpriseProjectEndpoint = @{ value = $enterpriseProjectEndpoint }
        enterpriseAgentName = @{ value = $EnterpriseAgentName }
        consumerFoundryAccountName = @{ value = $consumerAccountName }
        consumerFoundryProjectName = @{ value = $ConsumerProjectName }
        apiPath = @{ value = $ApiPath }
        inboundAudience = @{ value = $InboundAudience }
        allowedCallerObjectIds = @{ value = @($LocalCallerObjectId) }
    }
} | ConvertTo-Json -Depth 8 | Set-Content $paramsPath -Encoding utf8

Write-Host "Deploying the keyless APIM A2A facade and consumer connection..." -ForegroundColor Cyan
& $az deployment group create `
    --name $DeploymentName `
    --resource-group $ResourceGroup `
    --template-file $template `
    --parameters "@$paramsPath" `
    --output none
$exitCode = $LASTEXITCODE
Remove-Item $paramsPath -ErrorAction SilentlyContinue
if ($exitCode -ne 0) { throw "APIM enterprise-agent deployment failed." }

$out = & $az deployment group show --name $DeploymentName --resource-group $ResourceGroup --query properties.outputs | ConvertFrom-Json
$config = if (Test-Path $outputsFile) { Get-Content $outputsFile -Raw -Encoding UTF8 | ConvertFrom-Json } else { [pscustomobject]@{} }
$values = [ordered]@{
    enterpriseProjectEndpoint = $enterpriseProjectEndpoint
    enterpriseAgentName = $EnterpriseAgentName
    enterpriseAgentDirectA2aUrl = $out.directA2aBaseUrl.value
    enterpriseAgentApimUrl = $out.publicA2aBaseUrl.value
    enterpriseAgentApimDiscoveryUrl = $out.publicA2aDiscoveryBaseUrl.value
    enterpriseAgentApimCardUrl = $out.publicAgentCardUrl.value
    enterpriseAgentConsumerConnectionId = $out.consumerA2aConnectionId.value
    enterpriseAgentInboundAudience = $InboundAudience
    enterpriseAgentInboundScope = "$($InboundAudience.TrimEnd('/'))/.default"
}
foreach ($entry in $values.GetEnumerator()) {
    $config | Add-Member -NotePropertyName $entry.Key -NotePropertyValue $entry.Value -Force
}
$config | ConvertTo-Json -Depth 10 | Set-Content $outputsFile -Encoding utf8

Write-Host "`nEnterprise Foundry agent is available through APIM." -ForegroundColor Green
Write-Host ("  Direct Foundry A2A : {0}" -f $out.directA2aBaseUrl.value)
Write-Host ("  APIM A2A           : {0}" -f $out.publicA2aBaseUrl.value)
Write-Host ("  APIM agent card    : {0}" -f $out.publicAgentCardUrl.value)
Write-Host ("  Local caller oid   : {0}" -f $LocalCallerObjectId)
Write-Host ("  Consumer project MI: {0}" -f $out.consumerProjectPrincipalId.value)
Write-Host ("  APIM backend MI    : {0}" -f $out.apimBackendPrincipalId.value)
Write-Host "`nRun both consumers:" -ForegroundColor Cyan
Write-Host "  python ../src/test/scenario4_maf_enterprise_agent_apim.py"
Write-Host "  python ../src/test/scenario4_foundry_agent_apim.py"
Write-Host "`nDirect Responses comparison (bypasses APIM):"
Write-Host "  python ../src/test/invoke_enterprise_foundry_agent_direct.py"
