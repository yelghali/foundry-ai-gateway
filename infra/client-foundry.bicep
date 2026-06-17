// =====================================================================================
//  Client Foundry — the "functional agent" that consumes ENTERPRISE resources
//  (companion to main.bicep; deploy AFTER main.bicep + litellm-foundry.bicep + a2a-agent)
//
//  Topology this file completes:
//
//    ┌──────────────── Enterprise (models) ────────────────┐
//    │  foundry1 (eastus2)      foundry2 (swedencentral)    │   <- main.bicep
//    │        └──────── APIM backend pool (load balanced) ──┘   <- "scenario 1"
//    │                         ▲           ▲                    │
//    └─────────────────────────┼───────────┼────────────────────┘
//                              │           │
//        ApiManagement conn ───┘           └─── ModelGateway conn (via LiteLLM)
//                              │           │
//                       ┌──────┴───────────┴──────┐
//                       │   CLIENT Foundry        │   <- THIS FILE (no models of its own)
//                       │   functional agent      │
//                       └─────────────────────────┘
//
//  For the heavy lifting the client reaches the enterprise models ONLY through
//  gateway connections, three ways:
//    1. ApiManagement connection  -> APIM /inference/openai      ("AI Gateway native")
//    2. ModelGateway  connection  -> LiteLLM                     ("BYO gateway")
//    3. CustomKeys    connection  -> APIM /inference/openai      ("custom, gateway URL")
//
//  ...and reaches tools the same governed way:
//    - MS Learn MCP behind APIM     (CustomKeys conn -> {apim}/learn-mcp/mcp)
//    - MS Learn MCP behind LiteLLM  (CustomKeys conn -> {litellm}/mcp/)
//    - Remote A2A specialist        (RemoteA2A conn  -> the agent's host-root card)
//
//  It also hosts ONE small native "driver" model deployment. Foundry's managed A2A
//  tool 500s when the calling agent's model is itself resolved through a gateway
//  connection, so the A2A agent must be driven by a real local deployment. (Plain
//  model calls and the MCP tool work fine over the gateway connections.)
// =====================================================================================

// ------------------
//    PARAMETERS
// ------------------

@description('Location for the client Foundry account.')
param location string = resourceGroup().location

@description('Base name of the client Foundry account (a unique suffix is appended).')
param clientAccountBaseName string = 'foundry-client'

@description('Name of the project created on the client account (the agent runtime).')
param clientProjectName string = 'aigateway-client'

@description('Name of the existing APIM service (main.bicep output apimServiceName).')
param apimServiceName string

@description('Existing APIM subscription whose key the client presents to the gateway.')
param apimSubscriptionName string = 'subscription1'

@description('Path to the inference API in APIM (main.bicep inferenceAPIPath + endpoint path).')
param inferenceApiPath string = 'inference/openai'

@description('Azure OpenAI API version Foundry appends to inference calls through APIM.')
param inferenceApiVersion string = '2024-10-21'

@description('Path to the MS Learn MCP passthrough API in APIM (main.bicep mslearnMcpUrl path).')
param learnMcpApiPath string = 'learn-mcp/mcp'

@description('Public FQDN of the existing LiteLLM Container App (litellm-foundry.bicep output gatewayFqdn).')
param litellmFqdn string

@description('LiteLLM master key (the connection credential).')
@secure()
param litellmMasterKey string

@description('Path to the LiteLLM re-exposed MCP endpoint (trailing slash matters).')
param litellmMcpPath string = 'mcp/'

@description('Host root of the remote A2A agent that serves a spec-compliant agent card at /.well-known/agent-card.json (a2a-agent.bicep public URL).')
param dummyA2aUrl string

@description('Model (deployment) name exposed by the gateways.')
param modelName string = 'gpt-4o-mini'

@description('Underlying model version (metadata only).')
param modelVersion string = '2024-07-18'

@description('Capacity (K TPM) for the small native driver deployment used to orchestrate the A2A tool.')
param driverModelCapacity int = 50

// ------------------
//    VARIABLES
// ------------------

var resourceSuffix = uniqueString(subscription().id, resourceGroup().id)
var clientAccountName = '${clientAccountBaseName}-${resourceSuffix}'

// Static model list registered on the model-serving connections (JSON string — Foundry
// requires complex metadata values to be serialized). "name" is the deployment id.
var modelsMetadata = '[{"name":"${modelName}","properties":{"model":{"name":"${modelName}","version":"${modelVersion}","format":"OpenAI"}}}]'
// LiteLLM expects "Authorization: Bearer <master_key>".
var litellmAuthConfig = '{"type":"api_key","name":"Authorization","format":"Bearer {api_key}"}'

var apimGatewayUrl = '${apimService.properties.gatewayUrl}/${inferenceApiPath}'
var apimMcpUrl = '${apimService.properties.gatewayUrl}/${learnMcpApiPath}'
var litellmBaseUrl = 'https://${litellmFqdn}'

// ------------------
//    EXISTING RESOURCES
// ------------------

resource apimService 'Microsoft.ApiManagement/service@2024-06-01-preview' existing = {
  name: apimServiceName
}

resource apimSubscription 'Microsoft.ApiManagement/service/subscriptions@2024-06-01-preview' existing = {
  parent: apimService
  name: apimSubscriptionName
}

// ------------------
//    CLIENT FOUNDRY ACCOUNT + PROJECT (no model deployments)
// ------------------

resource clientAccount 'Microsoft.CognitiveServices/accounts@2025-06-01' = {
  name: clientAccountName
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
    customSubDomainName: toLower(clientAccountName)
    disableLocalAuth: false
    publicNetworkAccess: 'Enabled'
  }
}

resource clientProject 'Microsoft.CognitiveServices/accounts/projects@2025-04-01-preview' = {
  #disable-next-line BCP334
  name: clientProjectName
  parent: clientAccount
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {}
}

// Small native "driver" model. Required for the managed A2A tool (which 500s when the
// calling agent's model is a gateway connection). NOT used for the model/MCP demos —
// those deliberately go through the enterprise gateway connections below.
resource driverModelDeployment 'Microsoft.CognitiveServices/accounts/deployments@2025-06-01' = {
  parent: clientAccount
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

// ------------------
//    MODEL CONNECTIONS (3 ways to reach the enterprise models)
// ------------------

// 1) "AI Gateway native" — Foundry's built-in ApiManagement connection -> APIM pool.
resource apimModelConnection 'Microsoft.CognitiveServices/accounts/connections@2025-04-01-preview' = {
  parent: clientAccount
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

// 2) "BYO gateway" — Model Gateway connection -> LiteLLM (load balances the 2 foundries).
resource litellmModelConnection 'Microsoft.CognitiveServices/accounts/connections@2025-04-01-preview' = {
  parent: clientAccount
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

// 3) "Custom, use the gateway URL" — generic CustomKeys connection holding the APIM
//    inference URL + subscription key. (Whether Foundry will serve a *model* through a
//    CustomKeys connection is exactly what the client agent script probes — categories
//    ApiManagement/ModelGateway are the supported model-serving forms.)
resource apimCustomConnection 'Microsoft.CognitiveServices/accounts/connections@2025-04-01-preview' = {
  parent: clientAccount
  name: 'apim-custom'
  properties: {
    category: 'CustomKeys'
    target: apimGatewayUrl
    authType: 'CustomKeys'
    credentials: {
      keys: {
        'api-key': apimSubscription.listSecrets().primaryKey
      }
    }
    metadata: {}
  }
}

// ------------------
//    TOOL CONNECTIONS (MCP + A2A, behind the gateways)
// ------------------

// MS Learn MCP behind APIM — the APIM passthrough API (api-key header).
resource mcpApimConnection 'Microsoft.CognitiveServices/accounts/connections@2025-04-01-preview' = {
  parent: clientAccount
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

// MS Learn MCP behind LiteLLM — LiteLLM's re-exposed /mcp/ (Authorization: Bearer).
resource mcpLitellmConnection 'Microsoft.CognitiveServices/accounts/connections@2025-04-01-preview' = {
  parent: clientAccount
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

// Remote A2A specialist — RemoteA2A connection whose target is the agent's host root
// (it serves /.well-known/agent-card.json there, so Foundry's managed A2A tool works).
resource a2aDirectConnection 'Microsoft.CognitiveServices/accounts/connections@2025-04-01-preview' = {
  parent: clientAccount
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

// ------------------
//    OUTPUTS
// ------------------

output clientAccountName string = clientAccountName
output clientProjectEndpoint string = '${clientAccount.properties.endpoint}api/projects/${clientProjectName}'
output apimModelDeploymentName string = 'apim-gateway/${modelName}'
output litellmModelDeploymentName string = 'litellm-gateway/${modelName}'
output customModelDeploymentName string = 'apim-custom/${modelName}'
output driverModelDeploymentName string = driverModelDeployment.name
output mcpApimConnectionId string = mcpApimConnection.id
output mcpLitellmConnectionId string = mcpLitellmConnection.id
output a2aDirectConnectionId string = a2aDirectConnection.id
