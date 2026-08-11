// =====================================================================================
//  Scenario 1 client Foundry — Foundry agent + Toolbox behind BYO Azure APIM
//
//  A dedicated client Foundry account (no enterprise models of its own) whose agent gets a
//  single versioned **Toolbox** holding the MCP server and the remote A2A specialist. Every
//  tool call crosses the customer-owned APIM gateway.
//
//  AUTHENTICATION — managed identity / Microsoft Entra first:
//    - sc1-toolbox       (RemoteTool)    -> this project's Toolbox MCP endpoint
//                                           authType ProjectManagedIdentity (no secret)
//    - mslearn-mcp-apim  (CustomKeys)    -> {apim}/learn-mcp-mi/mcp
//                                           authType ProjectManagedIdentity (no secret);
//                                           APIM validates the Entra token and pins the
//                                           `oid` claim to THIS project's managed identity
//    - dummy-a2a-apim    (RemoteA2A)     -> APIM host root (card + message legs)
//                                           authType ProjectManagedIdentity (no secret);
//                                           the Entra-protected APIs are added by
//                                           a2a-apim.bicep (run deploy-a2a-apim.ps1 after)
//    - apim-custom-key   (ApiManagement) -> APIM /inference/openai
//                                           ⚠️ KEY — LAST RESORT. This is the one remaining
//                                           secret in the scenario: a raw model connection
//                                           has no ProjectManagedIdentity path on the
//                                           customer-key ("bring your own gateway URL")
//                                           pattern this scenario demonstrates. Scenario 2
//                                           (client-foundry-sc2.bicep) shows the same model
//                                           leg with managed identity and no key at all.
//
//  Plus one small native gpt-4o-mini "driver" used to orchestrate the toolbox, and the
//  account's system-assigned identity granted **Cognitive Services User** on the enterprise
//  Foundry accounts.
// =====================================================================================

@description('Location for the Scenario 1 client Foundry account.')
param location string = resourceGroup().location

@description('Name of the Scenario 1 client Foundry account.')
param accountName string = 'client-foundry-sc1-${uniqueString(subscription().id, resourceGroup().id)}'

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

@description('Path to the key-protected MS Learn MCP passthrough API in APIM (kept for reference/compat).')
param learnMcpApiPath string = 'learn-mcp/mcp'

@description('Path of the Entra-protected (managed identity, no subscription key) MS Learn MCP API this scenario creates on the existing APIM.')
param learnMcpMiApiPath string = 'learn-mcp-mi'

@description('Audience the project managed identity requests its Entra token for, and that APIM validates. Override with your own app registration Application ID URI (api://...) if you front APIM with one.')
param entraAudience string = 'https://cognitiveservices.azure.com'

@description('Host root of the remote A2A agent (serves /.well-known/agent-card.json). Reported as an output for reference; the A2A leg itself goes through APIM.')
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
// Foundry User (formerly Azure AI User) — required by an identity invoking toolbox tools.
var foundryUserRoleId = '53ca6127-db72-4b80-b1b0-d745d6d5456d'

var modelsMetadata = '[{"name":"${modelName}","properties":{"model":{"name":"${modelName}","version":"${modelVersion}","format":"OpenAI"}}}]'
var apimGatewayUrl = '${apimService.properties.gatewayUrl}/${inferenceApiPath}'
var apimMcpKeyUrl = '${apimService.properties.gatewayUrl}/${learnMcpApiPath}'
var apimMcpMiUrl = '${apimService.properties.gatewayUrl}/${learnMcpMiApiPath}/mcp'
// Foundry's RemoteA2A resolver fetches the agent card from the target's HOST ROOT, so the
// A2A connection targets the APIM gateway root. a2a-apim.bicep serves the (rewritten) card
// there and routes message/send back through APIM.
var apimA2aRootUrl = apimService.properties.gatewayUrl
var toolboxName = 'scenario1-apim-toolbox'
var tenantId = subscription().tenantId

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

var projectEndpoint = '${account.properties.endpoint}api/projects/${projectName}'
var toolboxMcpUrl = '${projectEndpoint}/toolboxes/${toolboxName}/mcp?api-version=v1'

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

// MODEL (⚠️ KEY — LAST RESORT): the APIM subscription key carried on an ApiManagement
// connection. A raw CustomKeys connection cannot back a model, and this scenario exists to
// demonstrate the explicit "bring your own gateway URL + key" pattern. It is the ONLY
// credential in Scenario 1. Prefer Scenario 2 (apim-gateway-mi) when the model leg can use
// the project managed identity instead.
resource apimCustomKeyConnection 'Microsoft.CognitiveServices/accounts/connections@2025-04-01-preview' = {
  parent: account
  name: 'apim-custom-key'
  properties: {
    category: 'ApiManagement'
    authType: 'ApiKey'
    target: apimGatewayUrl
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

// -------------------------------------------------------------------------------------
//  ENTRA-PROTECTED MCP SURFACE ON THE EXISTING (CUSTOMER-OWNED) APIM
// -------------------------------------------------------------------------------------
// A second front door for the MS Learn MCP backend that main.bicep already registered.
// It requires NO subscription key: the only accepted credential is a Microsoft Entra token
// whose `oid` claim is this project's managed identity. APIM strips the token before the
// request leaves the gateway, so the upstream MCP server never sees it.
var mcpMiPolicyXml = '<policies><inbound><base /><validate-azure-ad-token tenant-id="${tenantId}" header-name="Authorization" failed-validation-httpcode="401" failed-validation-error-message="Unauthorized: a Microsoft Entra token from the Scenario 1 project managed identity is required."><audiences><audience>${entraAudience}</audience><audience>${entraAudience}/</audience></audiences><required-claims><claim name="oid" match="any"><value>${project.identity.principalId}</value></claim></required-claims></validate-azure-ad-token><set-backend-service backend-id="mslearn-mcp" /><set-header name="Authorization" exists-action="delete" /></inbound><backend><forward-request buffer-response="false" /></backend><outbound><base /></outbound><on-error><base /></on-error></policies>'

resource mcpMiApi 'Microsoft.ApiManagement/service/apis@2024-06-01-preview' = {
  name: 'mslearn-mcp-mi'
  parent: apimService
  properties: {
    apiType: 'http'
    description: 'MS Learn MCP through APIM, authenticated with Microsoft Entra (project managed identity). No subscription key.'
    displayName: 'MS Learn MCP (managed identity)'
    path: learnMcpMiApiPath
    protocols: [
      'https'
    ]
    subscriptionRequired: false
    type: 'http'
  }
}

resource mcpMiApiPolicy 'Microsoft.ApiManagement/service/apis/policies@2024-06-01-preview' = {
  name: 'policy'
  parent: mcpMiApi
  properties: {
    format: 'rawxml'
    value: mcpMiPolicyXml
  }
}

// MCP streamable HTTP uses POST (JSON-RPC), GET (SSE stream) and DELETE (end session).
resource mcpMiPostOperation 'Microsoft.ApiManagement/service/apis/operations@2024-06-01-preview' = {
  name: 'mcp-post'
  parent: mcpMiApi
  properties: {
    displayName: 'MCP request (JSON-RPC)'
    method: 'POST'
    urlTemplate: '/mcp'
  }
}

resource mcpMiGetOperation 'Microsoft.ApiManagement/service/apis/operations@2024-06-01-preview' = {
  name: 'mcp-get'
  parent: mcpMiApi
  properties: {
    displayName: 'MCP server stream (SSE)'
    method: 'GET'
    urlTemplate: '/mcp'
  }
}

resource mcpMiDeleteOperation 'Microsoft.ApiManagement/service/apis/operations@2024-06-01-preview' = {
  name: 'mcp-delete'
  parent: mcpMiApi
  properties: {
    displayName: 'MCP session terminate'
    method: 'DELETE'
    urlTemplate: '/mcp'
  }
}

// TOOL (MI): MS Learn MCP behind APIM. No key is stored anywhere — Foundry mints a token for
// `entraAudience` with the project managed identity and APIM validates it.
resource mcpApimConnection 'Microsoft.CognitiveServices/accounts/projects/connections@2025-04-01-preview' = {
  parent: project
  name: 'mslearn-mcp-apim'
  properties: {
    category: 'CustomKeys'
    target: apimMcpMiUrl
    #disable-next-line BCP036
    authType: 'ProjectManagedIdentity'
    audience: entraAudience
    credentials: {}
    metadata: {}
  }
  dependsOn: [
    mcpMiApiPolicy
  ]
}

// AGENT (MI): remote A2A specialist through APIM. Target is the APIM HOST ROOT because the
// RemoteA2A resolver reads the agent card from there; a2a-apim.bicep publishes that card
// (with the `url` rewritten back through APIM) and protects both legs with the same
// Entra-token validation. Deploy it with deploy-a2a-apim.ps1 after this template.
resource a2aApimConnection 'Microsoft.CognitiveServices/accounts/projects/connections@2025-04-01-preview' = {
  parent: project
  name: 'dummy-a2a-apim'
  properties: {
    category: 'RemoteA2A'
    target: apimA2aRootUrl
    #disable-next-line BCP036
    authType: 'ProjectManagedIdentity'
    audience: entraAudience
    credentials: {}
    metadata: {}
  }
}

// The prompt agent consumes the toolbox through its stable (default-version) MCP URL.
// Foundry obtains a project-MI token for https://ai.azure.com; no toolbox credential is
// present in code or stored as a key.
resource toolboxConnection 'Microsoft.CognitiveServices/accounts/projects/connections@2025-04-01-preview' = {
  parent: project
  name: 'sc1-toolbox'
  properties: {
    category: 'RemoteTool'
    target: toolboxMcpUrl
    #disable-next-line BCP036
    authType: 'ProjectManagedIdentity'
    audience: 'https://ai.azure.com'
    credentials: {}
    metadata: {}
  }
}

// The identity that invokes toolbox tools needs Foundry User on the project holding them.
resource projectIdentityFoundryUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(project.id, 'sc1-toolbox-caller', foundryUserRoleId)
  scope: project
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', foundryUserRoleId)
    principalId: project.identity.principalId
    principalType: 'ServicePrincipal'
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
output projectEndpoint string = projectEndpoint
output projectPrincipalId string = project.identity.principalId
output driverModelDeploymentName string = driverModelDeployment.name
output customKeyModelDeploymentName string = 'apim-custom-key/${modelName}'
output entraAudience string = entraAudience
output mcpApimMiUrl string = apimMcpMiUrl
output mcpApimKeyUrl string = apimMcpKeyUrl
output mcpApimConnectionId string = mcpApimConnection.id
output a2aDirectUrl string = dummyA2aUrl
output a2aApimUrl string = apimA2aRootUrl
output a2aApimConnectionId string = a2aApimConnection.id
output toolboxName string = toolboxName
output toolboxMcpUrl string = toolboxMcpUrl
output toolboxConnectionId string = toolboxConnection.id
