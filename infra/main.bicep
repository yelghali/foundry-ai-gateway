// =====================================================================================
//  APIM ❤️ AI Foundry — Backend pool load balancing (self-contained)
//  Deploys:
//    - Azure API Management (Standard v2) with a system-assigned managed identity
//    - N Azure AI Foundry (AIServices) accounts across regions, each with a project
//      and a model deployment
//    - Cognitive Services User role assignment for the APIM managed identity
//    - APIM backends (one per Foundry) + a load-balanced backend pool
//    - A keyless Inference API (Azure OpenAI shape) with Entra authentication,
//      retry, and load balancing
// =====================================================================================

// ------------------
//    PARAMETERS
// ------------------

@description('Location for the resource group resources that are not region-pinned (APIM).')
param location string = resourceGroup().location

@description('The pricing tier of the customer-owned API Management service.')
@allowed([
  'Basicv2'
  'Standardv2'
  'Premiumv2'
])
param apimSku string = 'Standardv2'

@description('Publisher email for the API Management service.')
param publisherEmail string = 'admin@contoso.com'

@description('Publisher name for the API Management service.')
param publisherName string = 'Contoso AI Platform'

@description('Configuration array for the Azure AI Foundry accounts. priority: lower = higher priority. weight: relative share within the same priority.')
param aiServicesConfig array = [
  {
    name: 'foundry1'
    location: 'eastus2'
    priority: 1
  }
  {
    name: 'foundry2'
    location: 'swedencentral'
    priority: 2
  }
]
@description('Configuration array for the model deployments created on every Foundry account.')
param modelsConfig array = [
  {
    name: 'gpt-4o-mini'
    version: '2024-07-18'
    sku: 'GlobalStandard'
    capacity: 20
  }
]
@description('Backend base URL for the MS Learn MCP passthrough API. The "/mcp" operation path is appended to it.')
param mslearnMcpBackendUrl string = 'https://learn.microsoft.com/api'

@description('Name of the Foundry project created on each account.')
param foundryProjectName string = 'aigateway'

// ------------------
//    VARIABLES
// ------------------

var resourceSuffix = uniqueString(subscription().id, resourceGroup().id)
var cognitiveServicesUserRoleId = 'a97b65f3-24c7-4388-baec-2e87135dc908' // Cognitive Services User
var inferenceBackendPoolName = 'inference-backend-pool'
var endpointPath = 'openai'
var miInferenceAPIName = 'inference-mi-api'
var miInferenceAPIPath = 'inference-mi'

// Flatten the (account x model) matrix so we can deploy every model on every account.
// map/flatten (with lambdas) is used instead of nested for-expressions, which Bicep
// does not allow as function arguments (BCP138).
var modelDeploymentMatrix = flatten(map(
  aiServicesConfig,
  (account, ai) =>
    map(modelsConfig, (model, mi) => {
      accountIndex: ai
      accountName: account.name
      model: model
    })
))

// The backend-id used by the policy: the pool when there are multiple backends, otherwise the single backend.
var policyBackendId = (length(aiServicesConfig) > 1) ? inferenceBackendPoolName : aiServicesConfig[0].name
var policyMiXml = replace(
  replace(
    replace(loadTextContent('policy-mi.xml'), '{backend-id}', policyBackendId),
    '{tenant-id}',
    subscription().tenantId
  ),
  '{caller-authorization}',
  ''
)

// ------------------
//    API MANAGEMENT
// ------------------

resource apimService 'Microsoft.ApiManagement/service@2024-06-01-preview' = {
  name: 'apim-${resourceSuffix}'
  location: location
  sku: {
    name: apimSku
    capacity: 1
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    publisherEmail: publisherEmail
    publisherName: publisherName
  }
}

resource apimLogAnalytics 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: 'log-apim-${resourceSuffix}'
  location: location
  properties: {
    features: {
      enableLogAccessUsingOnlyResourcePermissions: true
    }
    retentionInDays: 30
    sku: {
      name: 'PerGB2018'
    }
  }
}

resource apimDiagnosticSettings 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'apim-gateway-observability'
  scope: apimService
  properties: {
    logAnalyticsDestinationType: 'Dedicated'
    workspaceId: apimLogAnalytics.id
    logs: [
      {
        category: 'GatewayLogs'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
  }
}

// ------------------
//    AI FOUNDRY
// ------------------

resource cognitiveServices 'Microsoft.CognitiveServices/accounts@2025-06-01' = [
  for config in aiServicesConfig: {
    name: '${config.name}-${resourceSuffix}'
    location: config.location
    identity: {
      type: 'SystemAssigned'
    }
    sku: {
      name: 'S0'
    }
    kind: 'AIServices'
    properties: {
      allowProjectManagement: true
      customSubDomainName: toLower('${config.name}-${resourceSuffix}')
      disableLocalAuth: true
      publicNetworkAccess: 'Enabled'
    }
  }
]

resource aiProject 'Microsoft.CognitiveServices/accounts/projects@2025-04-01-preview' = [
  for (config, i) in aiServicesConfig: {
    #disable-next-line BCP334
    name: '${foundryProjectName}-${config.name}'
    parent: cognitiveServices[i]
    location: config.location
    identity: {
      type: 'SystemAssigned'
    }
    properties: {}
  }
]

// Allow the APIM managed identity to call the Foundry inference endpoints.
resource roleAssignmentCognitiveServicesUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for (config, i) in aiServicesConfig: {
    scope: cognitiveServices[i]
    name: guid(subscription().id, resourceGroup().id, config.name, cognitiveServicesUserRoleId)
    properties: {
      roleDefinitionId: resourceId('Microsoft.Authorization/roleDefinitions', cognitiveServicesUserRoleId)
      principalId: apimService.identity.principalId
      principalType: 'ServicePrincipal'
    }
  }
]

@batchSize(1)
resource modelDeployment 'Microsoft.CognitiveServices/accounts/deployments@2024-10-01' = [
  for (item, i) in modelDeploymentMatrix: {
    parent: cognitiveServices[item.accountIndex]
    name: item.model.name
    sku: {
      name: item.model.sku
      capacity: item.model.capacity
    }
    properties: {
      model: {
        format: 'OpenAI'
        name: item.model.name
        version: item.model.version
      }
    }
  }
]

// ------------------
//    APIM BACKENDS + POOL
// ------------------

resource inferenceBackend 'Microsoft.ApiManagement/service/backends@2024-06-01-preview' = [
  for (config, i) in aiServicesConfig: {
    name: config.name
    parent: apimService
    properties: {
      description: 'Inference backend for ${config.name}'
      url: '${cognitiveServices[i].properties.endpoint}${endpointPath}'
      protocol: 'http'
      circuitBreaker: {
        rules: [
          {
            failureCondition: {
              count: 1
              errorReasons: [
                'Server errors'
              ]
              interval: 'PT1M'
              statusCodeRanges: [
                {
                  min: 429
                  max: 429
                }
              ]
            }
            name: 'InferenceBreakerRule'
            tripDuration: 'PT1M'
            acceptRetryAfter: true
          }
        ]
      }
      credentials: {
        #disable-next-line BCP037
        managedIdentity: {
          resource: 'https://cognitiveservices.azure.com'
        }
      }
    }
  }
]

resource backendPool 'Microsoft.ApiManagement/service/backends@2024-06-01-preview' = if (length(aiServicesConfig) > 1) {
  name: inferenceBackendPoolName
  parent: apimService
  #disable-next-line BCP035
  properties: {
    description: 'Load balancer for multiple inference endpoints'
    type: 'Pool'
    pool: {
      services: [
        for (config, i) in aiServicesConfig: {
          id: '${apimService.id}/backends/${config.name}'
          priority: config.?priority
          weight: config.?weight
        }
      ]
    }
  }
  dependsOn: [
    inferenceBackend
  ]
}

// ---------------------------------
//    KEYLESS INFERENCE API
// ---------------------------------
// The inbound policy validates an Entra token before routing. The two-consumer extension
// replaces the initial tenant boundary with an explicit MAF + Foundry project oid allowlist.

resource inferenceMiApi 'Microsoft.ApiManagement/service/apis@2024-06-01-preview' = {
  name: miInferenceAPIName
  parent: apimService
  properties: {
    apiType: 'http'
    description: 'Managed-identity variant of the inference API (Entra token auth, no subscription key).'
    displayName: 'Inference API (Managed Identity)'
    path: '${miInferenceAPIPath}/${endpointPath}'
    protocols: [
      'https'
    ]
    subscriptionKeyParameterNames: {
      header: 'api-key'
      query: 'api-key'
    }
    subscriptionRequired: false
    type: 'http'
  }
}

resource inferenceMiApiPolicy 'Microsoft.ApiManagement/service/apis/policies@2024-06-01-preview' = {
  name: 'policy'
  parent: inferenceMiApi
  properties: {
    format: 'rawxml'
    value: policyMiXml
  }
  dependsOn: [
    backendPool
    inferenceBackend
  ]
}

resource miChatCompletionsOperation 'Microsoft.ApiManagement/service/apis/operations@2024-06-01-preview' = {
  name: 'chat-completions'
  parent: inferenceMiApi
  properties: {
    displayName: 'Creates a completion for the chat message'
    method: 'POST'
    urlTemplate: '/deployments/{deployment-id}/chat/completions'
    templateParameters: [
      {
        name: 'deployment-id'
        required: true
        type: 'string'
      }
    ]
  }
}

resource miCompletionsOperation 'Microsoft.ApiManagement/service/apis/operations@2024-06-01-preview' = {
  name: 'completions'
  parent: inferenceMiApi
  properties: {
    displayName: 'Creates a completion for the provided prompt'
    method: 'POST'
    urlTemplate: '/deployments/{deployment-id}/completions'
    templateParameters: [
      {
        name: 'deployment-id'
        required: true
        type: 'string'
      }
    ]
  }
}

resource miEmbeddingsOperation 'Microsoft.ApiManagement/service/apis/operations@2024-06-01-preview' = {
  name: 'embeddings'
  parent: inferenceMiApi
  properties: {
    displayName: 'Creates an embedding vector representing the input text'
    method: 'POST'
    urlTemplate: '/deployments/{deployment-id}/embeddings'
    templateParameters: [
      {
        name: 'deployment-id'
        required: true
        type: 'string'
      }
    ]
  }
}

// ------------------
//    MS LEARN MCP PASSTHROUGH API
// ------------------
// The repeatable two-consumer extension publishes this backend through an Entra-protected
// streamable HTTP API after the Foundry project identities exist.

resource mcpBackend 'Microsoft.ApiManagement/service/backends@2024-06-01-preview' = {
  name: 'mslearn-mcp'
  parent: apimService
  properties: {
    description: 'MS Learn remote MCP server'
    // Operation urlTemplate '/mcp' is appended -> https://learn.microsoft.com/api/mcp
    url: mslearnMcpBackendUrl
    protocol: 'http'
  }
}

// ------------------
//    OUTPUTS
// ------------------

output apimServiceId string = apimService.id
output apimServiceName string = apimService.name
output apimResourceGatewayURL string = apimService.properties.gatewayUrl
output apimLogAnalyticsWorkspaceId string = apimLogAnalytics.id
output apimLogAnalyticsWorkspaceName string = apimLogAnalytics.name
output apimDiagnosticSettingsName string = apimDiagnosticSettings.name
output miInferenceAPIPath string = miInferenceAPIPath

output foundryAccounts array = [
  for (config, i) in aiServicesConfig: {
    name: cognitiveServices[i].name
    location: config.location
    endpoint: cognitiveServices[i].properties.endpoint
    priority: config.?priority
    weight: config.?weight
  }
]
