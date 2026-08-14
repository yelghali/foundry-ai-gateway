<#
.SYNOPSIS
    Deploy the optional LiteLLM BYOM model, MCP, and A2A Foundry connections.
.DESCRIPTION
    Reads the live LiteLLM URL, model, and bearer credential from the canonical
    Terraform state. The credential is a secure deployment parameter and is never
    written to infra/scenario-outputs.json.
#>
param(
    [string]$ResourceGroup = "lab-foundry-ai-gateway",
    [string]$DeploymentName = "litellm-foundry-connections",
    [string]$AppProjectName = "aigateway-sc2",
    [string]$A2aAgentName = "dummy-specialist",
    [string]$TerraformDirectory = ""
)

$ErrorActionPreference = "Stop"
$az = if ($env:AZ_CMD) { $env:AZ_CMD } else { "az" }
$template = Join-Path $PSScriptRoot "litellm-foundry-connections.bicep"
$outputsFile = Join-Path $PSScriptRoot "scenario-outputs.json"
$repoRoot = Split-Path $PSScriptRoot -Parent
$testDir = Join-Path $repoRoot "src\test"
$python = Join-Path $testDir ".venv\Scripts\python.exe"
if (-not $TerraformDirectory) {
    $TerraformDirectory = Join-Path $repoRoot "litellm-gateway\litellm-azure-private-endpoints"
}

if (-not (Test-Path $outputsFile)) { throw "Run the core deployment scripts first." }
if (-not (Test-Path $python)) { throw "Create src/test/.venv and install src/test/requirements.txt first." }
$config = Get-Content $outputsFile -Raw -Encoding UTF8 | ConvertFrom-Json
$appAccount = $config.appFoundryAccountName
$a2aDirectUrl = $config.a2aDirectUrl
if (-not $appAccount -or -not $a2aDirectUrl) {
    throw "scenario-outputs.json must contain appFoundryAccountName and a2aDirectUrl."
}

$tfArg = "-chdir=$TerraformDirectory"
$litellmBaseUrl = (& terraform $tfArg output -raw litellm_url).Trim().TrimEnd('/')
$litellmApiKey = (& terraform $tfArg output -raw litellm_master_key).Trim()
$modelName = (& terraform $tfArg output -raw public_model_name).Trim()
if (-not $litellmBaseUrl -or -not $litellmApiKey -or -not $modelName) {
    throw "Could not read the LiteLLM URL, key, and model from Terraform outputs."
}

$subscriptionId = (& $az account show --query id -o tsv).Trim()
$accountRoot = "/subscriptions/$subscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.CognitiveServices/accounts/$appAccount"
$modelConnectionId = "$accountRoot/connections/litellm-gateway"
$mcpConnectionId = "$accountRoot/projects/$AppProjectName/connections/app-mcp-via-litellm"
$a2aConnectionId = "$accountRoot/projects/$AppProjectName/connections/app-a2a-via-litellm"

function Test-Resource([string]$resourceId) {
    & $az resource show --ids $resourceId --api-version 2025-04-01-preview --only-show-errors --output none 2>$null
    return $LASTEXITCODE -eq 0
}

$createModelConnection = -not (Test-Resource $modelConnectionId)
$createMcpConnection = -not (Test-Resource $mcpConnectionId)
$createA2aConnection = -not (Test-Resource $a2aConnectionId)

Write-Host "Registering '$A2aAgentName' in the LiteLLM A2A gateway..." -ForegroundColor Cyan
try {
    $env:LITELLM_BASE_URL = $litellmBaseUrl
    $env:LITELLM_MASTER_KEY = $litellmApiKey
    $env:A2A_URL_DIRECT = $a2aDirectUrl
    $env:A2A_AGENT_NAME = $A2aAgentName
    $registrationOutput = @(& $python (Join-Path $testDir "register_a2a_agent.py"))
    if ($LASTEXITCODE -ne 0) { throw "LiteLLM A2A registration failed." }
    $registrationOutput | ForEach-Object { Write-Host $_ }
    $agentIdLine = $registrationOutput | Where-Object { $_ -match '^A2A_AGENT_ID=' } | Select-Object -Last 1
    if (-not $agentIdLine) { throw "LiteLLM registration did not return an A2A agent ID." }
    $a2aAgentId = ($agentIdLine -replace '^A2A_AGENT_ID=', '').Trim()
} finally {
    Remove-Item Env:LITELLM_BASE_URL, Env:LITELLM_MASTER_KEY, Env:A2A_URL_DIRECT, Env:A2A_AGENT_NAME -ErrorAction SilentlyContinue
}

$paramsPath = Join-Path $env:TEMP "litellm_foundry_params.json"
@{
    '$schema' = "https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#"
    contentVersion = "1.0.0.0"
    parameters = @{
        appFoundryAccountName = @{ value = $appAccount }
        appFoundryProjectName = @{ value = $AppProjectName }
        litellmBaseUrl = @{ value = $litellmBaseUrl }
        litellmApiKey = @{ value = $litellmApiKey }
        modelName = @{ value = $modelName }
        a2aAgentId = @{ value = $a2aAgentId }
        createModelConnection = @{ value = $createModelConnection }
        createMcpConnection = @{ value = $createMcpConnection }
        createA2aConnection = @{ value = $createA2aConnection }
    }
} | ConvertTo-Json -Depth 8 | Set-Content $paramsPath -Encoding utf8

try {
    Write-Host "Deploying the optional LiteLLM Foundry connections and A2A shim..." -ForegroundColor Cyan
    & $az deployment group create `
        --name $DeploymentName `
        --resource-group $ResourceGroup `
        --template-file $template `
        --parameters "@$paramsPath" `
        --output none
    if ($LASTEXITCODE -ne 0) { throw "LiteLLM Foundry deployment failed." }
} finally {
    Remove-Item $paramsPath -ErrorAction SilentlyContinue
    $litellmApiKey = $null
}

$out = & $az deployment group show --name $DeploymentName --resource-group $ResourceGroup --query properties.outputs | ConvertFrom-Json
$values = [ordered]@{
    litellmBaseUrl = $out.litellmBaseUrl.value
    litellmModel = $out.litellmModel.value
    litellmModelConnectionId = $out.litellmModelConnectionId.value
    litellmMcpUrl = $out.litellmMcpUrl.value
    litellmMcpConnectionId = $out.litellmMcpConnectionId.value
    litellmA2aGatewayUrl = $out.litellmA2aGatewayUrl.value
    litellmA2aShimUrl = $out.litellmA2aShimUrl.value
    litellmA2aConnectionId = $out.litellmA2aConnectionId.value
}
foreach ($entry in $values.GetEnumerator()) {
    $config | Add-Member -NotePropertyName $entry.Key -NotePropertyValue $entry.Value -Force
}
$config | ConvertTo-Json -Depth 10 | Set-Content $outputsFile -Encoding utf8

Write-Host "`nOptional LiteLLM surfaces are ready." -ForegroundColor Green
Write-Host "  Model : $($out.litellmModel.value)"
Write-Host "  MCP   : $($out.litellmMcpUrl.value)"
Write-Host "  A2A   : $($out.litellmA2aShimUrl.value) -> $($out.litellmA2aGatewayUrl.value)"
