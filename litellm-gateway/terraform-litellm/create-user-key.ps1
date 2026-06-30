<#
.SYNOPSIS
  Create a LiteLLM virtual (user) key scoped to gpt-4.1 with a spend budget.

.DESCRIPTION
  Calls the LiteLLM admin API (POST /key/generate) using the master key. The new
  key can only call the given model(s); LiteLLM load balances those calls across
  the two regional Foundry backends behind the shared model name. Requires the
  DB-backed control plane (store_model_in_db = true), which this stack deploys.

.EXAMPLE
  ./create-user-key.ps1
  ./create-user-key.ps1 -Budget 50 -Model gpt-4.1 -Alias team-a -BudgetDuration 30d
#>
param(
  [double] $Budget = 50,
  [string] $Model = 'gpt-4.1',
  [string] $Alias = 'user-gpt41-50usd',
  [string] $BudgetDuration = '30d'
)

$ErrorActionPreference = 'Stop'
Set-Location -Path $PSScriptRoot

$baseUrl = (terraform output -raw litellm_url 2>$null)
if (-not $baseUrl -or $baseUrl -eq 'null') {
  $rg = (terraform output -raw resource_group_name).Trim()
  $app = (terraform output -raw container_app_name).Trim()
  $fqdn = az containerapp show -g $rg -n $app --query properties.configuration.ingress.fqdn -o tsv
  $baseUrl = "https://$fqdn"
}
$baseUrl = $baseUrl.Trim()
$masterKey = (terraform output -raw litellm_master_key).Trim()

$body = @{
  models          = @($Model)
  max_budget      = $Budget
  budget_duration = $BudgetDuration
  key_alias       = $Alias
} | ConvertTo-Json -Depth 5

Write-Host "Creating virtual key on $baseUrl" -ForegroundColor Cyan
Write-Host "  model(s)        : $Model" -ForegroundColor DarkGray
Write-Host "  budget          : `$$Budget / $BudgetDuration" -ForegroundColor DarkGray
Write-Host "  alias           : $Alias`n" -ForegroundColor DarkGray

try {
  $resp = Invoke-RestMethod -Uri "$baseUrl/key/generate" -Method Post `
    -Headers @{ Authorization = "Bearer $masterKey"; 'Content-Type' = 'application/json' } `
    -Body $body -TimeoutSec 60

  Write-Host "Virtual key created:" -ForegroundColor Green
  Write-Host "  KEY    : $($resp.key)" -ForegroundColor Yellow
  Write-Host "  budget : `$$($resp.max_budget)  duration: $($resp.budget_duration)"
  Write-Host "  models : $($resp.models -join ', ')"
  Write-Host "`nTest it:" -ForegroundColor Cyan
  Write-Host "  curl $baseUrl/v1/chat/completions -H 'Authorization: Bearer $($resp.key)' -H 'Content-Type: application/json' -d '{\"model\":\"$Model\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}'"
}
catch {
  Write-Host "FAILED to create key: $($_.Exception.Message)" -ForegroundColor Red
  if ($_.ErrorDetails.Message) { Write-Host $_.ErrorDetails.Message -ForegroundColor Red }
  throw
}
