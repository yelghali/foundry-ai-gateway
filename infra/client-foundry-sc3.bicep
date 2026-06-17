// =====================================================================================
//  Scenario 3 client Foundry — AI GATEWAY BYO (LiteLLM)
//
//  A dedicated client Foundry account whose model path is a self-hosted LiteLLM proxy
//  registered as a `ModelGateway` connection — the bring-your-own-gateway story, isolated
//  on its own Foundry resource. Same agent shape as Scenario 2, only the gateway differs.
//
//  Connections (clear, single-purpose):
//    - litellm-gateway     (ModelGateway) -> LiteLLM Container App   (model, BYO)
//    - mslearn-mcp-litellm (CustomKeys)   -> {litellm}/mcp/          (tool, same gateway)
//    - dummy-a2a-direct    (RemoteA2A)    -> the A2A agent host root (agent)
//  plus one small native gpt-4o-mini "driver" used to orchestrate the A2A leg.
// =====================================================================================

@description('Location for the Scenario 3 client Foundry account.')
param location string = resourceGroup().location

@description('Name of the Scenario 3 client Foundry account.')
param accountName string = 'client-foundry-sc3-${uniqueString(subscription().id, resourceGroup().id)}'

@description('Project (agent runtime) name created on the account.')
param projectName string = 'aigateway-sc3'

@description('Public FQDN of the existing LiteLLM Container App (litellm-foundry.bicep output gatewayFqdn).')
param litellmFqdn string

@description('LiteLLM master key (the connection credential).')
@secure()
param litellmMasterKey string

@description('Path to the LiteLLM re-exposed MCP endpoint (trailing slash matters).')
param litellmMcpPath string = 'mcp/'

@description('Host root of the remote A2A agent (serves /.well-known/agent-card.json).')
param dummyA2aUrl string

@description('Resource IDs of the enterprise Foundry accounts to grant this account MI data-plane access to.')
param enterpriseFoundryIds array = []

@description('Model (deployment) id exposed by the gateways.')
param modelName string = 'gpt-4o-mini'

@description('Underlying model version (metadata only).')
param modelVersion string = '2024-07-18'

@description('Capacity (K TPM) for the small native driver deployment used to orchestrate the A2A tool.')
param driverModelCapacity int = 50

var modelsMetadata = '[{"name":"${modelName}","properties":{"model":{"name":"${modelName}","version":"${modelVersion}","format":"OpenAI"}}}]'
var litellmAuthConfig = '{"type":"api_key","name":"Authorization","format":"Bearer {api_key}"}'
var litellmBaseUrl = 'https://${litellmFqdn}'
var cognitiveServicesUserRoleId = 'a97b65f3-24c7-4388-baec-2e87135dc908'

resource account 'Microsoft.CognitiveServices/accounts@2025-06-01' = {
  name: accountName
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  sku: {
    name: 'S0'
  }
  kind: 'AIServices'
  properties: {
    allowProjectManagement: true
    customSubDomainName: toLower(accountName)
    disableLocalAuth: false
    publicNetworkAccess: 'Enabled'
  }
}

resource project 'Microsoft.CognitiveServices/accounts/projects@2025-04-01-preview' = {
  #disable-next-line BCP334
  name: projectName
  parent: account
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {}
}

resource driverModelDeployment 'Microsoft.CognitiveServices/accounts/deployments@2025-06-01' = {
  parent: account
  name: modelName
  sku: {
    name: 'GlobalStandard'
    capacity: driverModelCapacity
  }
  properties: {
    model: {
      format: 'OpenAI'
      name: modelName
      version: modelVersion
    }
  }
}

// MODEL (BYO): LiteLLM registered as a ModelGateway connection.
resource litellmModelConnection 'Microsoft.CognitiveServices/accounts/connections@2025-04-01-preview' = {
  parent: account
  name: 'litellm-gateway'
  properties: {
    category: 'ModelGateway'
    target: litellmBaseUrl
    authType: 'ApiKey'
    credentials: {
      key: litellmMasterKey
    }
    metadata: {
      models: modelsMetadata
      deploymentInPath: 'false'
      authConfig: litellmAuthConfig
    }
  }
}

// TOOL: MS Learn MCP behind LiteLLM (Authorization: Bearer).
resource mcpLitellmConnection 'Microsoft.CognitiveServices/accounts/connections@2025-04-01-preview' = {
  parent: account
  name: 'mslearn-mcp-litellm'
  properties: {
    category: 'CustomKeys'
    target: '${litellmBaseUrl}/${litellmMcpPath}'
    authType: 'CustomKeys'
    credentials: {
      keys: {
        Authorization: 'Bearer ${litellmMasterKey}'
      }
    }
    metadata: {}
  }
}

// AGENT: remote A2A specialist via a RemoteA2A connection (host-root card).
resource a2aDirectConnection 'Microsoft.CognitiveServices/accounts/connections@2025-04-01-preview' = {
  parent: account
  name: 'dummy-a2a-direct'
  properties: {
    category: 'RemoteA2A'
    target: dummyA2aUrl
    authType: 'CustomKeys'
    credentials: {
      keys: {
        'x-noop': 'none'
      }
    }
    metadata: {}
  }
}

// Grant the account's managed identity data-plane access to the enterprise Foundry accounts.
resource enterpriseFoundry 'Microsoft.CognitiveServices/accounts@2025-06-01' existing = [for id in enterpriseFoundryIds: {
  name: last(split(id, '/'))
}]

resource miRoleAssignments 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for (id, i) in enterpriseFoundryIds: {
  name: guid(id, account.id, cognitiveServicesUserRoleId)
  scope: enterpriseFoundry[i]
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', cognitiveServicesUserRoleId)
    principalId: account.identity.principalId
    principalType: 'ServicePrincipal'
  }
}]

output accountName string = accountName
output projectEndpoint string = '${account.properties.endpoint}api/projects/${projectName}'
output driverModelDeploymentName string = driverModelDeployment.name
output litellmModelDeploymentName string = 'litellm-gateway/${modelName}'
output mcpLitellmConnectionId string = mcpLitellmConnection.id
output a2aDirectConnectionId string = a2aDirectConnection.id
