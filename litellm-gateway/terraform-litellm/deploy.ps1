<#
.SYNOPSIS
  Deploy the LiteLLM AI gateway (ACA + PostgreSQL Flexible Server + Key Vault + 2 Foundry backends).

.DESCRIPTION
  Wraps `terraform init/plan/apply`. Requires Terraform >= 1.5 and an authenticated
  Azure CLI session (`az login`) whose principal can create resources and assign roles.

.EXAMPLE
  ./deploy.ps1 -SubscriptionId <sub-id>
  ./deploy.ps1 -SubscriptionId <sub-id> -AutoApprove
#>
param(
  [Parameter(Mandatory = $true)] [string] $SubscriptionId,
  [switch] $AutoApprove,
  [switch] $PlanOnly
)

$ErrorActionPreference = 'Stop'
Set-Location -Path $PSScriptRoot

# Surface the subscription to the azurerm provider.
$env:ARM_SUBSCRIPTION_ID = $SubscriptionId

if (-not (Test-Path 'terraform.tfvars')) {
  Write-Host "No terraform.tfvars found; copying from example. Edit it before a real run." -ForegroundColor Yellow
  Copy-Item 'terraform.tfvars.example' 'terraform.tfvars'
}

terraform init -input=false
terraform fmt -recursive | Out-Null
terraform validate

$tfArgs = @('-input=false', "-var=subscription_id=$SubscriptionId")

if ($PlanOnly) {
  terraform plan @tfArgs
  return
}

if ($AutoApprove) {
  terraform apply -auto-approve @tfArgs
}
else {
  terraform apply @tfArgs
}

Write-Host "`nDeployment complete. Outputs:" -ForegroundColor Green
terraform output

Write-Host "`nRun the smoke test:  ./test.ps1" -ForegroundColor Cyan
