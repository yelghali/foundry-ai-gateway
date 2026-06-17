// =====================================================================================
//  APIM ❤️ AI Foundry — Backend pool load balancing (self-contained)
//  Deploys:
//    - Azure API Management (Standard v2) with a system-assigned managed identity
//    - N Azure AI Foundry (AIServices) accounts across regions, each with a project
//      and a model deployment
//    - Cognitive Services User role assignment for the APIM managed identity
//    - APIM backends (one per Foundry) + a load-balanced backend pool
//    - An Inference API (Azure OpenAI shape) with a retry + load-balancing policy
//    - An APIM subscription for client access
// =====================================================================================

// ------------------
//    PARAMETERS
// ------------------

@description('Location for the resource group resources that are not region-pinned (APIM).')
param location string = resourceGroup().location

@description('The pricing tier of the API Management service. Use a v2 tier to enable Foundry AI Gateway integration.')
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
    capacity: 8
  }
]

@description('Configuration array for APIM subscriptions.')
param apimSubscriptionsConfig array = [
  {
    name: 'subscription1'
    displayName: 'Subscription 1'
  }
]

@description('Path to the inference API in the APIM service.')
param inferenceAPIPath string = 'inference'

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
var inferenceAPIName = 'inference-api'
var endpointPath = 'openai'

// Flatten the (account x model) matrix so we can deploy every model on every account.
// map/flatten (with lambdas) is used instead of nested for-expressions, which Bicep
// does not allow as function arguments (BCP138).
var modelDeploymentMatrix = flatten(map(aiServicesConfig, (account, ai) => map(modelsConfig, (model, mi) => {
  accountIndex: ai
  accountName: account.name
  model: model
})))

// The backend-id used by the policy: the pool when there are multiple backends, otherwise the single backend.
var policyBackendId = (length(aiServicesConfig) > 1) ? inferenceBackendPoolName : aiServicesConfig[0].name
var policyXml = replace(loadTextContent('policy.xml'), '{backend-id}', policyBackendId)

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

@batchSize(1)
resource apimSubscription 'Microsoft.ApiManagement/service/subscriptions@2024-06-01-preview' = [
  for subscription in apimSubscriptionsConfig: {
    name: subscription.name
    parent: apimService
    properties: {
      allowTracing: true
      displayName: subscription.displayName
      scope: '/apis'
      state: 'active'
    }
  }
]

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
      disableLocalAuth: false
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
  // BCP035: protocol and url are not needed for the Pool type.
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

// ------------------
//    INFERENCE API
// ------------------

resource inferenceApi 'Microsoft.ApiManagement/service/apis@2024-06-01-preview' = {
  name: inferenceAPIName
  parent: apimService
  properties: {
    apiType: 'http'
    description: 'Azure OpenAI inference API, load balanced across Azure AI Foundry backends.'
    displayName: 'Inference API'
    path: '${inferenceAPIPath}/${endpointPath}'
    protocols: [
      'https'
    ]
    subscriptionKeyParameterNames: {
      header: 'api-key'
      query: 'api-key'
    }
    subscriptionRequired: true
    type: 'http'
  }
}

resource inferenceApiPolicy 'Microsoft.ApiManagement/service/apis/policies@2024-06-01-preview' = {
  name: 'policy'
  parent: inferenceApi
  properties: {
    format: 'rawxml'
    value: policyXml
  }
  dependsOn: [
    backendPool
    inferenceBackend
  ]
}

resource chatCompletionsOperation 'Microsoft.ApiManagement/service/apis/operations@2024-06-01-preview' = {
  name: 'chat-completions'
  parent: inferenceApi
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

resource completionsOperation 'Microsoft.ApiManagement/service/apis/operations@2024-06-01-preview' = {
  name: 'completions'
  parent: inferenceApi
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

resource embeddingsOperation 'Microsoft.ApiManagement/service/apis/operations@2024-06-01-preview' = {
  name: 'embeddings'
  parent: inferenceApi
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
// Exposes the public MS Learn remote MCP server THROUGH APIM, so the gateway governs
// *tool* (MCP) traffic the same way it governs *model* traffic. Agents point their MCP
// client at {gateway}/learn-mcp/mcp with the api-key header; APIM proxies the streamable
// HTTP/SSE to https://learn.microsoft.com/api/mcp.

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

resource mcpApi 'Microsoft.ApiManagement/service/apis@2024-06-01-preview' = {
  name: 'mslearn-mcp'
  parent: apimService
  properties: {
    apiType: 'http'
    description: 'MS Learn remote MCP server, proxied through APIM (governs tool/MCP traffic).'
    displayName: 'MS Learn MCP'
    path: 'learn-mcp'
    protocols: [
      'https'
    ]
    subscriptionKeyParameterNames: {
      header: 'api-key'
      query: 'api-key'
    }
    subscriptionRequired: true
    type: 'http'
  }
}

resource mcpApiPolicy 'Microsoft.ApiManagement/service/apis/policies@2024-06-01-preview' = {
  name: 'policy'
  parent: mcpApi
  properties: {
    format: 'rawxml'
    // buffer-response="false" keeps the MCP streamable-HTTP / SSE responses flowing.
    value: '<policies><inbound><base /><set-backend-service backend-id="mslearn-mcp" /></inbound><backend><forward-request buffer-response="false" /></backend><outbound><base /></outbound><on-error><base /></on-error></policies>'
  }
  dependsOn: [
    mcpBackend
  ]
}

// MCP streamable HTTP uses POST (JSON-RPC requests), GET (open SSE stream) and DELETE
// (terminate session) against the single /mcp endpoint.
resource mcpPostOperation 'Microsoft.ApiManagement/service/apis/operations@2024-06-01-preview' = {
  name: 'mcp-post'
  parent: mcpApi
  properties: {
    displayName: 'MCP request (JSON-RPC)'
    method: 'POST'
    urlTemplate: '/mcp'
  }
}

resource mcpGetOperation 'Microsoft.ApiManagement/service/apis/operations@2024-06-01-preview' = {
  name: 'mcp-get'
  parent: mcpApi
  properties: {
    displayName: 'MCP server stream (SSE)'
    method: 'GET'
    urlTemplate: '/mcp'
  }
}

resource mcpDeleteOperation 'Microsoft.ApiManagement/service/apis/operations@2024-06-01-preview' = {
  name: 'mcp-delete'
  parent: mcpApi
  properties: {
    displayName: 'MCP session terminate'
    method: 'DELETE'
    urlTemplate: '/mcp'
  }
}

// ------------------
//    OUTPUTS
// ------------------

output apimServiceId string = apimService.id
output apimServiceName string = apimService.name
output apimResourceGatewayURL string = apimService.properties.gatewayUrl
output inferenceAPIPath string = inferenceAPIPath

@description('Full URL of the MS Learn MCP server proxied through APIM. Use as the MCP client URL with the api-key header.')
output mslearnMcpUrl string = '${apimService.properties.gatewayUrl}/learn-mcp/mcp'

output foundryAccounts array = [
  for (config, i) in aiServicesConfig: {
    name: cognitiveServices[i].name
    location: config.location
    endpoint: cognitiveServices[i].properties.endpoint
    priority: config.?priority
    weight: config.?weight
  }
]

#disable-next-line outputs-should-not-contain-secrets
output apimSubscriptions array = [
  for (subscription, i) in apimSubscriptionsConfig: {
    name: subscription.name
    displayName: subscription.displayName
    key: apimSubscription[i].listSecrets().primaryKey
  }
]
