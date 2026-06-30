<#
.SYNOPSIS
  Deploy/configure LiteLLM on top of EXISTING infra, using Terraform (app-only).

.DESCRIPTION
  Reads the infra outputs (from ../terraform-litellm state by default) and creates
  the LiteLLM Container App. Auth to the Foundries is the infra's user-assigned
  managed identity (keyless). Run `terraform apply` for just the app.

.EXAMPLE
  ./deploy.ps1 -SubscriptionId <sub-id>
#>
param(
  [Parameter(Mandatory = $true)] [string] $SubscriptionId,
  [switch] $AutoApprove,
  [switch] $PlanOnly
)

$ErrorActionPreference = 'Stop'
Set-Location -Path $PSScriptRoot
$env:ARM_SUBSCRIPTION_ID = $SubscriptionId

terraform init -input=false
terraform fmt | Out-Null
terraform validate

$tfArgs = @('-input=false', "-var=subscription_id=$SubscriptionId")
if ($PlanOnly) { terraform plan @tfArgs; return }
if ($AutoApprove) { terraform apply -auto-approve @tfArgs } else { terraform apply @tfArgs }

Write-Host "`nDeployed. Outputs:" -ForegroundColor Green
terraform output
Write-Host "`nSmoke test:  ./test.ps1     Budgeted key:  ./create-user-key.ps1" -ForegroundColor Cyan
