<#
.SYNOPSIS
  Tail LiteLLM gateway logs from Log Analytics.

.DESCRIPTION
  Queries the Container Apps console logs for the LiteLLM revision via the
  Log Analytics workspace this stack created. Requires the Azure CLI
  (`az login`) and the log-analytics extension (installed on first use).

.EXAMPLE
  ./logs.ps1
  ./logs.ps1 -Minutes 60 -Grep error
#>
param(
  [int] $Minutes = 30,
  [string] $Grep = ''
)

$ErrorActionPreference = 'Stop'
Set-Location -Path $PSScriptRoot

$rg = (terraform output -raw resource_group_name).Trim()

# Resolve the workspace + container app names from the deployed resources.
$wsName = az monitor log-analytics workspace list -g $rg --query "[?starts_with(name,'log-')].name | [0]" -o tsv
$wsId = az monitor log-analytics workspace show -g $rg -n $wsName --query customerId -o tsv
$caName = az containerapp list -g $rg --query "[?starts_with(name,'ca-')].name | [0]" -o tsv

$filter = if ($Grep) { "| where Log_s contains '$Grep'" } else { '' }
$query = @"
ContainerAppConsoleLogs_CL
| where ContainerAppName_s == '$caName'
| where TimeGenerated > ago(${Minutes}m)
$filter
| project TimeGenerated, Log_s
| order by TimeGenerated asc
| take 200
"@

Write-Host "Workspace: $wsName   App: $caName   Window: ${Minutes}m`n" -ForegroundColor Cyan
az monitor log-analytics query --workspace $wsId --analytics-query $query -o table
