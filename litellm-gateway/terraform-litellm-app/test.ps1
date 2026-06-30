<#
.SYNOPSIS
  Smoke-test the LiteLLM gateway deployed by this app module (health, models,
  chat, and a load-balance burst across the two Foundry regions).
#>
param([int] $Requests = 6)

$ErrorActionPreference = 'Stop'
Set-Location -Path $PSScriptRoot

$baseUrl = (terraform output -raw litellm_url).Trim()
$key = (terraform output -raw litellm_master_key).Trim()
$model = (terraform output -raw public_model_name).Trim()

Write-Host "Gateway: $baseUrl" -ForegroundColor Cyan
Write-Host "Model:   $model`n" -ForegroundColor Cyan

try {
  $live = Invoke-WebRequest -Uri "$baseUrl/health/liveliness" -UseBasicParsing -TimeoutSec 30
  Write-Host "[1] liveness   : $($live.StatusCode) $($live.Content)" -ForegroundColor Green
}
catch { Write-Host "[1] liveness   : FAILED - $($_.Exception.Message)" -ForegroundColor Red }

try {
  $models = Invoke-RestMethod -Uri "$baseUrl/v1/models" -Headers @{ Authorization = "Bearer $key" } -TimeoutSec 30
  Write-Host "[2] models     : $(($models.data | ForEach-Object { $_.id }) -join ', ')" -ForegroundColor Green
}
catch { Write-Host "[2] models     : FAILED - $($_.Exception.Message)" -ForegroundColor Red }

$body = @{ model = $model; messages = @(@{ role = 'user'; content = 'In one sentence, what does an AI gateway do?' }); max_tokens = 40 } | ConvertTo-Json -Depth 6
try {
  $resp = Invoke-RestMethod -Uri "$baseUrl/v1/chat/completions" -Method Post -Headers @{ Authorization = "Bearer $key"; 'Content-Type' = 'application/json' } -Body $body -TimeoutSec 60
  Write-Host "[3] chat       : $($resp.choices[0].message.content)" -ForegroundColor Green
}
catch { Write-Host "[3] chat       : FAILED - $($_.Exception.Message)" -ForegroundColor Red }

Write-Host "`n[4] load balancing over $Requests requests:" -ForegroundColor Cyan
$backends = @{}
for ($i = 1; $i -le $Requests; $i++) {
  try {
    $r = Invoke-WebRequest -Uri "$baseUrl/v1/chat/completions" -Method Post -Headers @{ Authorization = "Bearer $key"; 'Content-Type' = 'application/json' } -Body $body -UseBasicParsing -TimeoutSec 60
    $api = $r.Headers['x-litellm-api-base']; if (-not $api) { $api = 'unknown' }; if ($api -is [array]) { $api = $api[0] }
    if ($backends.ContainsKey($api)) { $backends[$api]++ } else { $backends[$api] = 1 }
    Write-Host "    req $i -> $api" -ForegroundColor DarkGray
  }
  catch { Write-Host "    req $i -> FAILED $($_.Exception.Message)" -ForegroundColor Red }
}
Write-Host "`nBackend distribution:" -ForegroundColor Cyan
$backends.GetEnumerator() | ForEach-Object { Write-Host ("    {0,-60} {1}" -f $_.Key, $_.Value) }
