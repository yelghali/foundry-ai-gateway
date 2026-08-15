<#
.SYNOPSIS
    Deploy the optional LiteLLM BYOM model, MCP, and A2A Foundry connections.
.DESCRIPTION
    Reads the live LiteLLM URL and administrator credential from the canonical
    Terraform state. It creates or reuses a budgeted workshop virtual key in Key
    user-bound DPAPI storage, then stores that scoped key in the Foundry
    connections and A2A shim. No credential is written to the repository.
#>
param(
    [string]$ResourceGroup = "lab-foundry-ai-gateway",
    [string]$DeploymentName = "litellm-foundry-connections",
    [string]$AppProjectName = "aigateway-sc2",
    [string]$A2aAgentName = "dummy-specialist",
    [string]$TerraformDirectory = "",
    [string]$WorkshopKeyFile = "",
    [string]$WorkshopKeyAlias = "foundry-ai-gateway-workshop",
    [double]$WorkshopKeyBudget = 25,
    [string]$WorkshopKeyBudgetDuration = "30d",
    [switch]$RotateWorkshopKey
)

$ErrorActionPreference = "Stop"
$az = if ($env:AZ_CMD) { $env:AZ_CMD } else { "az" }
$template = Join-Path $PSScriptRoot "litellm-foundry-connections.bicep"
$outputsFile = Join-Path $PSScriptRoot "scenario-outputs.json"
$repoRoot = Split-Path $PSScriptRoot -Parent
$testDir = Join-Path $repoRoot "src\test"
$python = Join-Path $testDir ".venv\Scripts\python.exe"
if (-not $TerraformDirectory) {
    $TerraformDirectory = Join-Path $repoRoot "litellm-gateway\litellm-azure-private-endpoints"
}
if (-not $WorkshopKeyFile) {
    $WorkshopKeyFile = Join-Path $env:LOCALAPPDATA "foundry-ai-gateway\litellm-workshop-key.clixml"
}

if (-not (Test-Path $outputsFile)) { throw "Run the core deployment scripts first." }
if (-not (Test-Path $python)) { throw "Create src/test/.venv and install src/test/requirements.txt first." }
$config = Get-Content $outputsFile -Raw -Encoding UTF8 | ConvertFrom-Json
$appAccount = $config.appFoundryAccountName
$a2aDirectUrl = $config.a2aDirectUrl
if (-not $appAccount -or -not $a2aDirectUrl) {
    throw "scenario-outputs.json must contain appFoundryAccountName and a2aDirectUrl."
}

$tfArg = "-chdir=$TerraformDirectory"
function Get-TerraformOutput([string]$name) {
    $output = & terraform $tfArg output -raw $name
    if ($LASTEXITCODE -ne 0 -or $null -eq $output) {
        throw "Could not read Terraform output '$name'."
    }
    $value = ($output | Out-String).Trim()
    if (-not $value -or $value -eq "null") {
        throw "Terraform output '$name' is empty."
    }
    return $value
}

$litellmBaseUrl = (Get-TerraformOutput "litellm_url").TrimEnd('/')
$litellmMasterKey = Get-TerraformOutput "litellm_master_key"
$modelName = Get-TerraformOutput "public_model_name"

$subscriptionOutput = & $az account show --query id -o tsv
if ($LASTEXITCODE -ne 0 -or $null -eq $subscriptionOutput) {
    throw "Could not read the active Azure subscription ID."
}
$subscriptionId = ($subscriptionOutput | Out-String).Trim()
if (-not $subscriptionId) {
    throw "The active Azure subscription ID is empty."
}
$expectedApimServiceId = "/subscriptions/$subscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.ApiManagement/service/$($config.apimServiceName)"
if ($config.resourceGroup -ne $ResourceGroup -or $config.apimServiceId -ne $expectedApimServiceId) {
    throw "scenario-outputs.json does not belong to the active subscription and target resource group. Refresh it with the core deployment scripts."
}

Write-Host "Registering '$A2aAgentName' in the LiteLLM A2A gateway..." -ForegroundColor Cyan
$registrationEnvironmentNames = @(
    "LITELLM_BASE_URL",
    "LITELLM_MASTER_KEY",
    "A2A_URL_DIRECT",
    "A2A_AGENT_NAME"
)
$registrationEnvironment = @{}
foreach ($name in $registrationEnvironmentNames) {
    $registrationEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, "Process")
}
try {
    $env:LITELLM_BASE_URL = $litellmBaseUrl
    $env:LITELLM_MASTER_KEY = $litellmMasterKey
    $env:A2A_URL_DIRECT = $a2aDirectUrl
    $env:A2A_AGENT_NAME = $A2aAgentName
    $registrationOutput = @(& $python (Join-Path $testDir "register_a2a_agent.py"))
    if ($LASTEXITCODE -ne 0) { throw "LiteLLM A2A registration failed." }
    $registrationOutput | ForEach-Object { Write-Host $_ }
    $agentIdLine = $registrationOutput | Where-Object { $_ -match '^A2A_AGENT_ID=' } | Select-Object -Last 1
    if (-not $agentIdLine) { throw "LiteLLM registration did not return an A2A agent ID." }
    $a2aAgentId = ($agentIdLine -replace '^A2A_AGENT_ID=', '').Trim()
} finally {
    foreach ($name in $registrationEnvironmentNames) {
        [Environment]::SetEnvironmentVariable($name, $registrationEnvironment[$name], "Process")
    }
}

function Remove-LiteLLMKey([string]$key) {
    if (-not $key) { return }
    Invoke-RestMethod `
        -Uri "$litellmBaseUrl/key/delete" `
        -Method Post `
        -Headers @{ Authorization = "Bearer $litellmMasterKey"; "Content-Type" = "application/json" } `
        -Body (@{ keys = @($key) } | ConvertTo-Json) `
        -TimeoutSec 60 | Out-Null
}

function Test-ExactStringSet($actual, $expected) {
    $actualValues = @($actual | ForEach-Object { "$_" } | Sort-Object -Unique)
    $expectedValues = @($expected | ForEach-Object { "$_" } | Sort-Object -Unique)
    return $actualValues.Count -eq $expectedValues.Count -and
        $null -eq (Compare-Object $actualValues $expectedValues)
}

function Test-LiteLLMWorkshopKey([string]$key) {
    try {
        $keyInfo = (Invoke-RestMethod `
            -Uri "$litellmBaseUrl/key/info?key=$([uri]::EscapeDataString($key))" `
            -Headers @{ Authorization = "Bearer $litellmMasterKey" } `
            -TimeoutSec 60).info
        $mcpServers = @(Invoke-RestMethod `
            -Uri "$litellmBaseUrl/v1/mcp/server" `
            -Headers @{ Authorization = "Bearer $litellmMasterKey" } `
            -TimeoutSec 60)
        $expectedMcpServers = @($mcpServers | Where-Object {
            $_.server_name -eq "mslearn" -or $_.alias -eq "mslearn"
        })
        if ($expectedMcpServers.Count -ne 1) {
            throw "Expected exactly one LiteLLM MCP server named 'mslearn'."
        }
    } catch {
        Write-Warning "The stored LiteLLM workshop key could not be validated and will be rotated."
        return $false
    }

    $expiresAt = if ($keyInfo.expires) { [DateTimeOffset]::Parse($keyInfo.expires) } else { $null }
    $mcpToolPermissionCount = if ($null -eq $keyInfo.object_permission.mcp_tool_permissions) {
        0
    } else {
        @($keyInfo.object_permission.mcp_tool_permissions.PSObject.Properties).Count
    }
    $matchesScope = `
        -not $keyInfo.blocked -and `
        (-not $expiresAt -or $expiresAt -gt [DateTimeOffset]::UtcNow) -and `
        (Test-ExactStringSet $keyInfo.models @($modelName)) -and `
        [double]$keyInfo.max_budget -eq $WorkshopKeyBudget -and `
        $keyInfo.budget_duration -eq $WorkshopKeyBudgetDuration -and `
        (Test-ExactStringSet $keyInfo.object_permission.mcp_servers @($expectedMcpServers[0].server_id)) -and `
        (Test-ExactStringSet $keyInfo.object_permission.agents @($a2aAgentId)) -and `
        -not $keyInfo.user_id -and `
        -not $keyInfo.team_id -and `
        -not $keyInfo.organization_id -and `
        -not $keyInfo.project_id -and `
        @($keyInfo.access_group_ids).Count -eq 0 -and `
        @($keyInfo.object_permission.models).Count -eq 0 -and `
        @($keyInfo.object_permission.mcp_access_groups).Count -eq 0 -and `
        $mcpToolPermissionCount -eq 0 -and `
        @($keyInfo.object_permission.mcp_toolsets).Count -eq 0 -and `
        @($keyInfo.object_permission.agent_access_groups).Count -eq 0
    if (-not $matchesScope) {
        Write-Warning "The stored LiteLLM workshop key no longer matches the configured scope and will be rotated."
    }
    return $matchesScope
}

$litellmApiKey = $null
$previousWorkshopKey = $null
$generatedWorkshopKey = $false
$deploymentSucceeded = $false
$deploymentStarted = $false
$pendingKeyFile = "$WorkshopKeyFile.pending"
if (Test-Path $pendingKeyFile) {
    throw "A pending DPAPI workshop key exists at '$pendingKeyFile'. Resolve that interrupted deployment before continuing."
}
if (Test-Path $WorkshopKeyFile) {
    $storedCredential = Import-Clixml $WorkshopKeyFile
    if ($storedCredential -isnot [System.Management.Automation.PSCredential]) {
        throw "The stored workshop key is not a DPAPI-protected PowerShell credential."
    }
    $storedWorkshopKey = $storedCredential.GetNetworkCredential().Password
    if ($RotateWorkshopKey -or -not (Test-LiteLLMWorkshopKey $storedWorkshopKey)) {
        $previousWorkshopKey = $storedWorkshopKey
    } else {
        $litellmApiKey = $storedWorkshopKey
    }
    $storedWorkshopKey = $null
}

$paramsPath = Join-Path $env:TEMP "litellm_foundry_params.json"
try {
    if (-not $litellmApiKey) {
        Write-Host "Creating a budgeted LiteLLM workshop key..." -ForegroundColor Cyan
        $keyRequest = @{
            models = @($modelName)
            max_budget = $WorkshopKeyBudget
            budget_duration = $WorkshopKeyBudgetDuration
            key_alias = "$WorkshopKeyAlias-$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())"
            object_permission = @{
                mcp_servers = @("mslearn")
                agents = @($a2aAgentId)
            }
        } | ConvertTo-Json -Depth 5
        $keyResponse = Invoke-RestMethod `
            -Uri "$litellmBaseUrl/key/generate" `
            -Method Post `
            -Headers @{ Authorization = "Bearer $litellmMasterKey"; "Content-Type" = "application/json" } `
            -Body $keyRequest `
            -TimeoutSec 60
        $litellmApiKey = $keyResponse.key
        if (-not $litellmApiKey) {
            throw "LiteLLM did not return a workshop key."
        }
        $generatedWorkshopKey = $true
        if (-not (Test-LiteLLMWorkshopKey $litellmApiKey)) {
            throw "The generated LiteLLM workshop key does not match the requested scope."
        }
        $keyDirectory = Split-Path $WorkshopKeyFile -Parent
        New-Item -ItemType Directory -Path $keyDirectory -Force | Out-Null
        $secureKey = ConvertTo-SecureString $litellmApiKey -AsPlainText -Force
        [System.Management.Automation.PSCredential]::new("litellm-workshop", $secureKey) |
            Export-Clixml -Path $pendingKeyFile -Force
    }

    @{
        '$schema' = "https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#"
        contentVersion = "1.0.0.0"
        parameters = @{
            appFoundryAccountName = @{ value = $appAccount }
            appFoundryProjectName = @{ value = $AppProjectName }
            litellmBaseUrl = @{ value = $litellmBaseUrl }
            litellmApiKey = @{ value = $litellmApiKey }
            modelName = @{ value = $modelName }
            a2aAgentId = @{ value = $a2aAgentId }
            credentialRevision = @{ value = [guid]::NewGuid().ToString("N") }
        }
    } | ConvertTo-Json -Depth 8 | Set-Content $paramsPath -Encoding utf8

    Write-Host "Deploying the optional LiteLLM Foundry connections and A2A shim..." -ForegroundColor Cyan
    $deploymentStarted = $true
    & $az deployment group create `
        --name $DeploymentName `
        --resource-group $ResourceGroup `
        --template-file $template `
        --parameters "@$paramsPath" `
        --output none
    if ($LASTEXITCODE -ne 0) { throw "LiteLLM Foundry deployment failed." }
    $deploymentSucceeded = $true
    if ($generatedWorkshopKey) {
        Move-Item $pendingKeyFile $WorkshopKeyFile -Force
        if ($previousWorkshopKey -and $previousWorkshopKey -ne $litellmApiKey) {
            try {
                Remove-LiteLLMKey $previousWorkshopKey
            } catch {
                Write-Warning "The previous workshop key could not be revoked; remove its old alias in LiteLLM."
            }
        }
    }
} catch {
    if ($generatedWorkshopKey -and -not $deploymentSucceeded) {
        if ($deploymentStarted) {
            Write-Warning "Azure deployment may have partially applied the generated key. Both old and new keys remain active, and the encrypted new key remains at '$pendingKeyFile' for reconciliation."
        } else {
            try {
                Remove-LiteLLMKey $litellmApiKey
            } catch {
                Write-Warning "The generated workshop key could not be rolled back; remove its alias in LiteLLM."
            }
            Remove-Item $pendingKeyFile -Force -ErrorAction SilentlyContinue
        }
    } elseif ($generatedWorkshopKey -and (Test-Path $pendingKeyFile)) {
        Write-Warning "Azure accepted the new key, but local commit failed. The encrypted key remains at '$pendingKeyFile'."
    }
    throw
} finally {
    Remove-Item $paramsPath -ErrorAction SilentlyContinue
    $litellmApiKey = $null
    $litellmMasterKey = $null
    $previousWorkshopKey = $null
}

$deploymentOutput = & $az deployment group show --name $DeploymentName --resource-group $ResourceGroup --query properties.outputs
if ($LASTEXITCODE -ne 0 -or $null -eq $deploymentOutput) {
    throw "Could not read the optional LiteLLM deployment outputs."
}
$out = $deploymentOutput | ConvertFrom-Json
$requiredOutputs = @(
    "litellmBaseUrl",
    "litellmModel",
    "litellmModelConnectionId",
    "litellmMcpUrl",
    "litellmMcpConnectionId",
    "litellmA2aGatewayUrl",
    "litellmA2aShimUrl",
    "litellmA2aConnectionId"
)
foreach ($name in $requiredOutputs) {
    if (-not $out.$name.value) {
        throw "Optional LiteLLM deployment output '$name' is missing."
    }
}
$values = [ordered]@{
    litellmBaseUrl = $out.litellmBaseUrl.value
    litellmModel = $out.litellmModel.value
    litellmModelConnectionId = $out.litellmModelConnectionId.value
    litellmMcpUrl = $out.litellmMcpUrl.value
    litellmMcpConnectionId = $out.litellmMcpConnectionId.value
    litellmA2aGatewayUrl = $out.litellmA2aGatewayUrl.value
    litellmA2aShimUrl = $out.litellmA2aShimUrl.value
    litellmA2aConnectionId = $out.litellmA2aConnectionId.value
}
foreach ($entry in $values.GetEnumerator()) {
    $config | Add-Member -NotePropertyName $entry.Key -NotePropertyValue $entry.Value -Force
}
$tempOutputsFile = "$outputsFile.tmp"
$config | ConvertTo-Json -Depth 10 | Set-Content $tempOutputsFile -Encoding utf8
Move-Item $tempOutputsFile $outputsFile -Force

Write-Host "`nOptional LiteLLM surfaces are ready." -ForegroundColor Green
Write-Host "  Model : $($out.litellmModel.value)"
Write-Host "  MCP   : $($out.litellmMcpUrl.value)"
Write-Host "  A2A   : $($out.litellmA2aShimUrl.value) -> $($out.litellmA2aGatewayUrl.value)"
Write-Host "  Key   : scoped workshop credential stored with Windows DPAPI (value not displayed)"
Write-Host "          Run infra/copy-litellm-workshop-key.ps1 to copy it for approved distribution."
