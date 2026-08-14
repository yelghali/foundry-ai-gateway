<#
.SYNOPSIS
    Deploy the repeatable APIM surfaces shared by MAF and Foundry-hosted consumers.
.DESCRIPTION
    Tightens the model API allowlist, publishes the raw MCP server and Foundry Toolbox
    through APIM, and creates the Toolbox project connection only when it does not exist.
#>
param(
    [string]$ResourceGroup = "lab-foundry-ai-gateway",
    [string]$MainDeploymentName = "backend-pool-load-balancing",
    [string]$DeploymentName = "two-consumer-apim",
    [string]$ToolboxAccountPrefix = "client-foundry-sc1-",
    [string]$ToolboxProjectName = "aigateway-sc1",
    [string]$ModelConsumerAccountPrefix = "client-foundry-sc2-",
    [string]$ModelConsumerProjectName = "aigateway-sc2",
    [string]$LocalCallerObjectId = "",
    [string]$InboundAudience = "https://cognitiveservices.azure.com"
)

$ErrorActionPreference = "Stop"
$az = if ($env:AZ_CMD) { $env:AZ_CMD } else { "az" }
$template = Join-Path $PSScriptRoot "two-consumer-apim.bicep"
$outputsFile = Join-Path $PSScriptRoot "scenario-outputs.json"

function Find-Account([string]$prefix) {
    $name = (& $az cognitiveservices account list --resource-group $ResourceGroup --query "[?starts_with(name, '$prefix')].name | [0]" -o tsv).Trim()
    if (-not $name) { throw "Could not find a Foundry account with prefix '$prefix' in '$ResourceGroup'." }
    return $name
}

function Get-ProjectEndpoint([string]$accountName, [string]$projectName) {
    $accountEndpoint = (& $az cognitiveservices account show --resource-group $ResourceGroup --name $accountName --query properties.endpoint -o tsv).Trim()
    if (-not $accountEndpoint) { throw "Could not read the endpoint for '$accountName'." }
    $servicesEndpoint = ($accountEndpoint -replace "\.cognitiveservices\.azure\.com", ".services.ai.azure.com").TrimEnd('/')
    return "$servicesEndpoint/api/projects/$projectName"
}

$main = & $az deployment group show --name $MainDeploymentName --resource-group $ResourceGroup --query properties.outputs | ConvertFrom-Json
$apimName = $main.apimServiceName.value
$toolboxAccount = Find-Account $ToolboxAccountPrefix
$modelConsumerAccount = Find-Account $ModelConsumerAccountPrefix
$toolboxProjectEndpoint = Get-ProjectEndpoint $toolboxAccount $ToolboxProjectName
$modelConsumerProjectEndpoint = Get-ProjectEndpoint $modelConsumerAccount $ModelConsumerProjectName

if (-not $LocalCallerObjectId) {
    try {
        $LocalCallerObjectId = (& $az ad signed-in-user show --query id -o tsv).Trim()
    } catch { }
}
if (-not $LocalCallerObjectId) {
    throw "Could not resolve the local MAF caller object ID. Pass -LocalCallerObjectId explicitly."
}

$subscriptionId = (& $az account show --query id -o tsv).Trim()
$toolboxConnectionId = "/subscriptions/$subscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.CognitiveServices/accounts/$toolboxAccount/projects/$ToolboxProjectName/connections/toolbox-via-apim"
& $az resource show --ids $toolboxConnectionId --api-version 2025-04-01-preview --only-show-errors --output none 2>$null
$createToolboxConnection = $LASTEXITCODE -ne 0
$mcpConnectionId = "/subscriptions/$subscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.CognitiveServices/accounts/$toolboxAccount/projects/$ToolboxProjectName/connections/mcp-via-apim"
& $az resource show --ids $mcpConnectionId --api-version 2025-04-01-preview --only-show-errors --output none 2>$null
$createMcpConnection = $LASTEXITCODE -ne 0
$appMcpConnectionId = "/subscriptions/$subscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.CognitiveServices/accounts/$modelConsumerAccount/projects/$ModelConsumerProjectName/connections/app-mcp-via-apim"
& $az resource show --ids $appMcpConnectionId --api-version 2025-04-01-preview --only-show-errors --output none 2>$null
$createAppMcpConnection = $LASTEXITCODE -ne 0
$appToolboxConnectionId = "/subscriptions/$subscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.CognitiveServices/accounts/$modelConsumerAccount/projects/$ModelConsumerProjectName/connections/app-toolbox-via-apim"
& $az resource show --ids $appToolboxConnectionId --api-version 2025-04-01-preview --only-show-errors --output none 2>$null
$createAppToolboxConnection = $LASTEXITCODE -ne 0

$paramsPath = Join-Path $env:TEMP "two_consumer_apim_params.json"
@{
    '$schema' = "https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#"
    contentVersion = "1.0.0.0"
    parameters = @{
        apimServiceName = @{ value = $apimName }
        toolboxFoundryAccountName = @{ value = $toolboxAccount }
        toolboxFoundryProjectName = @{ value = $ToolboxProjectName }
        toolboxProjectEndpoint = @{ value = $toolboxProjectEndpoint }
        modelConsumerFoundryAccountName = @{ value = $modelConsumerAccount }
        modelConsumerFoundryProjectName = @{ value = $ModelConsumerProjectName }
        allowedCallerObjectIds = @{ value = @($LocalCallerObjectId) }
        inboundAudience = @{ value = $InboundAudience }
        createToolboxConnection = @{ value = $createToolboxConnection }
        createMcpConnection = @{ value = $createMcpConnection }
        createAppMcpConnection = @{ value = $createAppMcpConnection }
        createAppToolboxConnection = @{ value = $createAppToolboxConnection }
    }
} | ConvertTo-Json -Depth 8 | Set-Content $paramsPath -Encoding utf8

Write-Host "Deploying repeatable model, MCP, and Toolbox APIM surfaces..." -ForegroundColor Cyan
& $az deployment group create `
    --name $DeploymentName `
    --resource-group $ResourceGroup `
    --template-file $template `
    --parameters "@$paramsPath" `
    --output none
$exitCode = $LASTEXITCODE
Remove-Item $paramsPath -ErrorAction SilentlyContinue
if ($exitCode -ne 0) { throw "Two-consumer APIM deployment failed." }

$out = & $az deployment group show --name $DeploymentName --resource-group $ResourceGroup --query properties.outputs | ConvertFrom-Json
$config = if (Test-Path $outputsFile) { Get-Content $outputsFile -Raw -Encoding UTF8 | ConvertFrom-Json } else { [pscustomobject]@{} }
$values = [ordered]@{
    apimGatewayUrl = "https://$apimName.azure-api.net"
    modelApimMiUrl = $out.modelApiUrl.value
    modelApimMiPath = "inference-mi"
    enterpriseModel = "gpt-4o-mini"
    inferenceApiVersion = "2024-10-21"
    appProjectEndpoint = $modelConsumerProjectEndpoint
    appModel = "apim-gateway-mi/gpt-4o-mini"
    appDriverModel = "gpt-4o-mini"
    appMcpConnectionId = $out.appMcpConnectionId.value
    appToolboxConnectionId = $out.appToolboxConnectionId.value
    toolboxProjectEndpoint = $toolboxProjectEndpoint
    rawMcpApimUrl = $out.mcpApiUrl.value
    toolboxPublisherMcpConnectionId = $out.mcpConnectionId.value
    toolboxName = "scenario1-apim-toolbox"
    toolboxMcpUrl = "$toolboxProjectEndpoint/toolboxes/scenario1-apim-toolbox/mcp?api-version=v1"
    # Legacy aliases retained for older standalone samples.
    sc1ProjectEndpoint = $toolboxProjectEndpoint
    sc1DriverModel = "gpt-4o-mini"
    sc1McpApimMiUrl = $out.mcpApiUrl.value
    sc1McpApimConnId = $out.mcpConnectionId.value
    sc1ToolboxName = "scenario1-apim-toolbox"
    sc1ToolboxMcpUrl = "$toolboxProjectEndpoint/toolboxes/scenario1-apim-toolbox/mcp?api-version=v1"
    toolboxApimUrl = $out.toolboxApiUrl.value
    toolboxApimConnectionId = $out.toolboxConnectionId.value
    apimInboundAudience = $InboundAudience
    apimInboundScope = "$($InboundAudience.TrimEnd('/'))/.default"
}
foreach ($entry in $values.GetEnumerator()) {
    $config | Add-Member -NotePropertyName $entry.Key -NotePropertyValue $entry.Value -Force
}
$config | ConvertTo-Json -Depth 10 | Set-Content $outputsFile -Encoding utf8

Write-Host "`nTwo-consumer APIM surfaces are ready." -ForegroundColor Green
Write-Host "  Model   : $($out.modelApiUrl.value)"
Write-Host "  MCP     : $($out.mcpApiUrl.value)"
Write-Host "  Toolbox : $($out.toolboxApiUrl.value)"
Write-Host "  Callers : $($out.allowedCallerObjectIds.value -join ', ')"
Write-Host "  APIM MI : $($out.apimPrincipalId.value)"