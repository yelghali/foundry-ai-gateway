<#
.SYNOPSIS
  Create a LiteLLM virtual (user) key scoped to a model, with a spend budget.
  Budgets/keys persist in PostgreSQL (survives app restarts).

.EXAMPLE
  ./create-user-key.ps1                       # gpt-4.1, $50 / 30d
  ./create-user-key.ps1 -Budget 50 -Model gpt-4.1 -Alias team-a -BudgetDuration 30d
#>
param(
  [double] $Budget = 50,
  [string] $Model = '',
  [string] $Alias = 'user-gpt41-50usd',
  [string] $BudgetDuration = '30d'
)

$ErrorActionPreference = 'Stop'
Set-Location -Path $PSScriptRoot

$baseUrl = (terraform output -raw litellm_url).Trim()
$masterKey = (terraform output -raw litellm_master_key).Trim()
if (-not $Model) { $Model = (terraform output -raw public_model_name).Trim() }

$body = @{ models = @($Model); max_budget = $Budget; budget_duration = $BudgetDuration; key_alias = $Alias } | ConvertTo-Json -Depth 5
Write-Host "Creating `$$Budget/$BudgetDuration virtual key for $Model on $baseUrl ..." -ForegroundColor Cyan
try {
  $resp = Invoke-RestMethod -Uri "$baseUrl/key/generate" -Method Post -Headers @{ Authorization = "Bearer $masterKey"; 'Content-Type' = 'application/json' } -Body $body -TimeoutSec 60
  Write-Host "  KEY    : $($resp.key)" -ForegroundColor Yellow
  Write-Host "  budget : `$$($resp.max_budget) / $($resp.budget_duration)   models: $($resp.models -join ', ')"
}
catch {
  Write-Host "FAILED: $($_.Exception.Message)" -ForegroundColor Red
  if ($_.ErrorDetails.Message) { Write-Host $_.ErrorDetails.Message -ForegroundColor Red }
  throw
}
