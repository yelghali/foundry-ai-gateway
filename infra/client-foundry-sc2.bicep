// =====================================================================================
//  Scenario 2 client Foundry — AI GATEWAY NATIVE (APIM)
//
//  A dedicated client Foundry account whose model path is Foundry's first-class
//  `ApiManagement` connection to the enterprise APIM gateway. Because the native AI Gateway
//  integration is configured at the **Foundry resource level**, giving Scenario 2 its own
//  account keeps that gateway story clean and isolated.
//
//  The native gateway is exercised **managed-identity-first, key-fallback**: the agent tries
//  the project's managed identity (AAD connection) first and falls back to the subscription
//  key connection. MI through APIM additionally requires the APIM inbound policy to validate
//  the project MI token (validate-azure-ad-token); the run reports the real outcome honestly.
//
//  Connections (clear, single-purpose):
//    - apim-gateway-mi  (ApiManagement) -> APIM /inference/openai   (model, native, AAD/MI)
//    - apim-gateway     (ApiManagement) -> APIM /inference/openai   (model, native, KEY)
//    - mslearn-mcp-apim (CustomKeys)    -> {apim}/learn-mcp/mcp      (tool, same gateway)
//    - dummy-a2a-direct (RemoteA2A)     -> the A2A agent host root   (agent)
//  plus one small native gpt-4o-mini "driver" used to orchestrate the A2A leg.
// =====================================================================================

@description('Location for the Scenario 2 client Foundry account.')
param location string = resourceGroup().location

@description('Full name of the Scenario 2 client Foundry account (already suffixed by the orchestrator).')
param accountName string

@description('Project (agent runtime) name created on the account.')
param projectName string = 'aigateway-sc2'

@description('Existing APIM service name (main.bicep output apimServiceName).')
param apimServiceName string

@description('Existing APIM subscription whose key the connection presents to APIM.')
param apimSubscriptionName string = 'subscription1'

@description('Path to the inference API in APIM (e.g. inference/openai).')
param inferenceApiPath string = 'inference/openai'

@description('Azure OpenAI API version Foundry appends to inference calls through APIM.')
param inferenceApiVersion string = '2024-10-21'

@description('Path to the MS Learn MCP passthrough API in APIM.')
param learnMcpApiPath string = 'learn-mcp/mcp'

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
var apimGatewayUrl = '${apimService.properties.gatewayUrl}/${inferenceApiPath}'
var apimMcpUrl = '${apimService.properties.gatewayUrl}/${learnMcpApiPath}'
var cognitiveServicesUserRoleId = 'a97b65f3-24c7-4388-baec-2e87135dc908'

resource apimService 'Microsoft.ApiManagement/service@2024-06-01-preview' existing = {
  name: apimServiceName
}

resource apimSubscription 'Microsoft.ApiManagement/service/subscriptions@2024-06-01-preview' existing = {
  parent: apimService
  name: apimSubscriptionName
}

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

// MODEL (native, MI): Foundry's first-class ApiManagement connection authenticated by the
// project's managed identity (AAD). Static `models` metadata means model discovery needs no
// call, so the connection resolves and any failure surfaces honestly at inference time.
resource apimModelMiConnection 'Microsoft.CognitiveServices/accounts/connections@2025-04-01-preview' = {
  parent: account
  name: 'apim-gateway-mi'
  properties: {
    category: 'ApiManagement'
    target: apimGatewayUrl
    authType: 'AAD'
    metadata: {
      models: modelsMetadata
      deploymentInPath: 'true'
      inferenceAPIVersion: inferenceApiVersion
    }
  }
}

// MODEL (native, KEY): the same first-class ApiManagement connection, subscription-key auth.
// This is the fallback the scenario uses when the managed-identity leg is not accepted.
resource apimModelConnection 'Microsoft.CognitiveServices/accounts/connections@2025-04-01-preview' = {
  parent: account
  name: 'apim-gateway'
  properties: {
    category: 'ApiManagement'
    target: apimGatewayUrl
    authType: 'ApiKey'
    credentials: {
      key: apimSubscription.listSecrets().primaryKey
    }
    metadata: {
      models: modelsMetadata
      deploymentInPath: 'true'
      inferenceAPIVersion: inferenceApiVersion
    }
  }
}

// TOOL: MS Learn MCP behind the same APIM gateway (api-key header).
resource mcpApimConnection 'Microsoft.CognitiveServices/accounts/connections@2025-04-01-preview' = {
  parent: account
  name: 'mslearn-mcp-apim'
  properties: {
    category: 'CustomKeys'
    target: apimMcpUrl
    authType: 'CustomKeys'
    credentials: {
      keys: {
        'api-key': apimSubscription.listSecrets().primaryKey
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
output apimModelDeploymentName string = 'apim-gateway/${modelName}'
output apimMiModelDeploymentName string = 'apim-gateway-mi/${modelName}'
output mcpApimConnectionId string = mcpApimConnection.id
output a2aDirectConnectionId string = a2aDirectConnection.id
