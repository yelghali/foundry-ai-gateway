<#
.SYNOPSIS
    Remove all lab resources to stop charges.
#>
param(
    [string]$ResourceGroup = "lab-foundry-ai-gateway"
)
$az = if ($env:AZ_CMD) { $env:AZ_CMD } else { "az" }
Write-Host "Deleting resource group '$ResourceGroup'..." -ForegroundColor Yellow
& $az group delete --name $ResourceGroup --yes --no-wait
Write-Host "Delete initiated (running in background). APIM soft-delete may retain the name for 48h." -ForegroundColor Yellow
