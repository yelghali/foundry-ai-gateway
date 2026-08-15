<#
.SYNOPSIS
    Show recent model, MCP, Toolbox, and A2A requests exported by APIM.
.DESCRIPTION
    Reads the predeployed APIM and Log Analytics metadata from scenario-outputs.json,
    then queries the resource-specific ApiManagementGatewayLogs table. No deployment
    or configuration change is performed.
#>
param(
    [ValidateRange(1, 10080)]
    [int]$LookbackMinutes = 60,
    [ValidateRange(1, 500)]
    [int]$Limit = 50
)

$ErrorActionPreference = "Stop"
$az = if ($env:AZ_CMD) { $env:AZ_CMD } else { "az" }
$configPath = Join-Path $PSScriptRoot "..\..\infra\scenario-outputs.json"

if (-not (Test-Path $configPath)) {
    throw "Missing infra/scenario-outputs.json. The lab must already be deployed."
}

$config = Get-Content $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
$workspaceId = $config.apimLogAnalyticsWorkspaceId
if (-not $workspaceId) {
    throw "APIM Log Analytics metadata is missing. Ask the facilitator to refresh the predeployed lab metadata."
}

$workspaceOutput = & $az monitor log-analytics workspace show `
    --ids $workspaceId `
    --query customerId `
    --output tsv
if ($LASTEXITCODE -ne 0 -or $null -eq $workspaceOutput) {
    throw "Could not resolve the Log Analytics workspace customer ID."
}
$workspaceCustomerId = ($workspaceOutput | Out-String).Trim()
if (-not $workspaceCustomerId) {
    throw "The Log Analytics workspace customer ID is empty."
}

$query = @"
ApiManagementGatewayLogs
| where TimeGenerated > ago(${LookbackMinutes}m)
| extend Surface = case(
    ApiId == 'inference-mi-api', 'Model',
    ApiId == 'mslearn-mcp-mi', 'Raw MCP',
    ApiId startswith 'foundry-toolbox-', 'Toolbox',
    ApiId startswith 'enterprise-foundry-agent-', 'A2A agent',
    'Other')
| where Surface != 'Other'
| project TimeGenerated, Surface, Method, ResponseCode, TotalTime, BackendTime, ApiId, OperationId, CorrelationId
| order by TimeGenerated desc
| take $Limit
"@
$query = $query -replace "\r?\n", " "

Write-Host "APIM requests from the last $LookbackMinutes minutes" -ForegroundColor Cyan
Write-Host "Workspace: $($config.apimLogAnalyticsWorkspaceName)"
& $az monitor log-analytics query `
    --workspace $workspaceCustomerId `
    --analytics-query $query `
    --output table
if ($LASTEXITCODE -ne 0) {
    throw "The Log Analytics query failed. New workspaces can take several minutes to expose their first table."
}