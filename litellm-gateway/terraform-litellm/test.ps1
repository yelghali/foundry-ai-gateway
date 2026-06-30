<#
.SYNOPSIS
  Smoke-test the deployed LiteLLM gateway: health, model list, a chat completion,
  and a small burst to show load balancing across the two regions.

.DESCRIPTION
  Reads the endpoint + master key from `terraform output`. Run after deploy.ps1.

.EXAMPLE
  ./test.ps1
  ./test.ps1 -Requests 10
#>
param(
  [int] $Requests = 6
)

$ErrorActionPreference = 'Stop'
Set-Location -Path $PSScriptRoot

function Resolve-BaseUrl {
  $u = (terraform output -raw litellm_url 2>$null)
  if ($u -and $u -ne 'null') { return $u.Trim() }
  # Terraform is infra-only; resolve the Container App FQDN directly.
  $rg = (terraform output -raw resource_group_name).Trim()
  $app = (terraform output -raw container_app_name).Trim()
  $fqdn = az containerapp show -g $rg -n $app --query properties.configuration.ingress.fqdn -o tsv
  return "https://$fqdn"
}

$baseUrl = Resolve-BaseUrl
$key = (terraform output -raw litellm_master_key).Trim()
$model = (terraform output -raw public_model_name).Trim()

Write-Host "Gateway: $baseUrl" -ForegroundColor Cyan
Write-Host "Model:   $model`n" -ForegroundColor Cyan

# 1) Liveness (no auth)
try {
  $live = Invoke-WebRequest -Uri "$baseUrl/health/liveliness" -UseBasicParsing -TimeoutSec 30
  Write-Host "[1] liveness   : $($live.StatusCode) $($live.Content)" -ForegroundColor Green
}
catch {
  Write-Host "[1] liveness   : FAILED - $($_.Exception.Message)" -ForegroundColor Red
}

# 2) Model list (auth)
try {
  $models = Invoke-RestMethod -Uri "$baseUrl/v1/models" -Headers @{ Authorization = "Bearer $key" } -TimeoutSec 30
  $ids = ($models.data | ForEach-Object { $_.id }) -join ', '
  Write-Host "[2] models     : $ids" -ForegroundColor Green
}
catch {
  Write-Host "[2] models     : FAILED - $($_.Exception.Message)" -ForegroundColor Red
}

# 3) Single chat completion
$body = @{
  model    = $model
  messages = @(@{ role = 'user'; content = 'In one sentence, what does an AI gateway do?' })
  max_tokens = 40
} | ConvertTo-Json -Depth 6

try {
  $resp = Invoke-RestMethod -Uri "$baseUrl/v1/chat/completions" -Method Post `
    -Headers @{ Authorization = "Bearer $key"; 'Content-Type' = 'application/json' } `
    -Body $body -TimeoutSec 60
  Write-Host "[3] chat       : $($resp.choices[0].message.content)" -ForegroundColor Green
}
catch {
  Write-Host "[3] chat       : FAILED - $($_.Exception.Message)" -ForegroundColor Red
}

# 4) Burst to exercise load balancing across the two regional backends
Write-Host "`n[4] load balancing over $Requests requests:" -ForegroundColor Cyan
$backends = @{}
for ($i = 1; $i -le $Requests; $i++) {
  try {
    $r = Invoke-WebRequest -Uri "$baseUrl/v1/chat/completions" -Method Post `
      -Headers @{ Authorization = "Bearer $key"; 'Content-Type' = 'application/json' } `
      -Body $body -UseBasicParsing -TimeoutSec 60
    # LiteLLM returns the chosen deployment in this response header.
    $api = $r.Headers['x-litellm-api-base']
    if (-not $api) { $api = $r.Headers['x-litellm-model-api-base'] }
    if (-not $api) { $api = 'unknown (header not exposed)' }
    if ($api -is [array]) { $api = $api[0] }
    if ($backends.ContainsKey($api)) { $backends[$api]++ } else { $backends[$api] = 1 }
    Write-Host "    req $i -> $api" -ForegroundColor DarkGray
  }
  catch {
    Write-Host "    req $i -> FAILED $($_.Exception.Message)" -ForegroundColor Red
  }
}

Write-Host "`nBackend distribution:" -ForegroundColor Cyan
$backends.GetEnumerator() | ForEach-Object { Write-Host ("    {0,-60} {1}" -f $_.Key, $_.Value) }
