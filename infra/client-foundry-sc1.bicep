// =====================================================================================
//  Scenario 1 client Foundry — CUSTOM (APIM), subscription-KEY auth
//
//  A dedicated client Foundry account (no enterprise models of its own) that reaches the
//  enterprise gateway with a *custom* connection authenticated by the APIM subscription KEY.
//  The customer brings the key explicitly (vs Scenario 2, where Foundry's own managed
//  identity authenticates natively). A raw `CustomKeys` connection cannot back a model
//  ("Category cannot be null"), so the key is carried on an `ApiManagement` connection —
//  the supported key path for the model leg.
//
//  Connections (clear, single-purpose):
//    - apim-custom-key   (ApiManagement) -> APIM /inference/openai   (model, KEY auth)
//    - mslearn-mcp-apim  (CustomKeys)    -> {apim}/learn-mcp/mcp     (tool)
//    - dummy-a2a-direct  (RemoteA2A)     -> the A2A agent host root  (agent)
//  plus one small native gpt-4o-mini "driver" used to orchestrate the A2A leg, and the
//  account's system-assigned identity granted **Cognitive Services User** on the enterprise
//  Foundry accounts.
// =====================================================================================

@description('Location for the Scenario 1 client Foundry account.')
param location string = resourceGroup().location

@description('Full name of the Scenario 1 client Foundry account (already suffixed by the orchestrator).')
param accountName string

@description('Project (agent runtime) name created on the account.')
param projectName string = 'aigateway-sc1'

@description('Existing APIM service name (main.bicep output apimServiceName).')
param apimServiceName string

@description('Existing APIM subscription whose key backs the custom connection.')
param apimSubscriptionName string = 'subscription1'

@description('Path to the inference API in APIM (e.g. inference/openai).')
param inferenceApiPath string = 'inference/openai'

@description('Azure OpenAI API version Foundry appends to inference calls through APIM.')
param inferenceApiVersion string = '2024-10-21'

@description('Path to the MS Learn MCP passthrough API in APIM.')
param learnMcpApiPath string = 'learn-mcp/mcp'

@description('Host root of the remote A2A agent (serves /.well-known/agent-card.json).')
param dummyA2aUrl string

@description('Resource IDs of the enterprise Foundry accounts to grant this account MI data-plane access to (Foundry User / Cognitive Services User).')
param enterpriseFoundryIds array = []

@description('Model (deployment) id exposed by the gateways.')
param modelName string = 'gpt-4o-mini'

@description('Underlying model version (metadata only).')
param modelVersion string = '2024-07-18'

@description('Capacity (K TPM) for the small native driver deployment used to orchestrate the A2A tool.')
param driverModelCapacity int = 50

// Cognitive Services User — data-plane access on the enterprise Foundry accounts.
var cognitiveServicesUserRoleId = 'a97b65f3-24c7-4388-baec-2e87135dc908'

var modelsMetadata = '[{"name":"${modelName}","properties":{"model":{"name":"${modelName}","version":"${modelVersion}","format":"OpenAI"}}}]'
var apimGatewayUrl = '${apimService.properties.gatewayUrl}/${inferenceApiPath}'
var apimMcpUrl = '${apimService.properties.gatewayUrl}/${learnMcpApiPath}'

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

// Small native driver model — required for the managed A2A tool (which 500s when the
// calling agent's model is a gateway connection). Not used for the model/MCP legs.
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

// MODEL (KEY): the APIM subscription key carried on an ApiManagement connection. A raw
// CustomKeys connection cannot back a model, so the supported key path is ApiManagement.
resource apimCustomKeyConnection 'Microsoft.CognitiveServices/accounts/connections@2025-04-01-preview' = {
  parent: account
  name: 'apim-custom-key'
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

// TOOL: MS Learn MCP behind APIM (api-key header).
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

// Grant the account's managed identity data-plane access to the enterprise Foundry
// accounts (Cognitive Services User), so the client foundries hold IAM on the enterprise side.
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
output accountPrincipalId string = account.identity.principalId
output projectEndpoint string = '${account.properties.endpoint}api/projects/${projectName}'
output driverModelDeploymentName string = driverModelDeployment.name
output customKeyModelDeploymentName string = 'apim-custom-key/${modelName}'
output mcpApimConnectionId string = mcpApimConnection.id
output a2aDirectConnectionId string = a2aDirectConnection.id
