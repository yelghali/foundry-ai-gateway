// =====================================================================================
// Enterprise Foundry agent exposed through APIM (A2A, keyless end to end).
//
// Inbound:  local MAF caller or consumer Foundry project MI -> APIM with an Entra token.
//           APIM validates tenant, audience, and an explicit oid allowlist.
// Backend:  APIM -> Foundry-hosted agent with APIM's system-assigned managed identity.
//           APIM has Foundry Agent Consumer on the enterprise project.
//
// The enterprise prompt agent and its incoming A2A endpoint are data-plane objects. Create
// them first with src/test/setup_enterprise_foundry_agent.py, then deploy this template.
// =====================================================================================

@description('Name of the existing enterprise APIM service.')
param apimServiceName string

@description('Name of the existing enterprise Foundry account that hosts the agent.')
param enterpriseFoundryAccountName string

@description('Name of the existing enterprise Foundry project that hosts the agent.')
param enterpriseFoundryProjectName string

@description('Project endpoint, for example https://account.services.ai.azure.com/api/projects/project.')
param enterpriseProjectEndpoint string

@description('Name of the Foundry agent whose incoming A2A endpoint is enabled.')
param enterpriseAgentName string = 'enterprise-specialist'

@description('Name of the existing consumer Foundry account.')
param consumerFoundryAccountName string

@description('Name of the existing consumer Foundry project.')
param consumerFoundryProjectName string = 'aigateway-sc2'

@description('Public APIM path for this agent.')
param apiPath string = 'enterprise-agents/enterprise-specialist'

@description('Entra audience accepted by APIM from callers. Use a dedicated api:// app URI in production.')
param inboundAudience string = 'https://cognitiveservices.azure.com'

@description('Additional Entra object IDs allowed to call APIM (for example local developers). The consumer project MI is included automatically.')
param allowedCallerObjectIds array

var foundryAudience = 'https://ai.azure.com'
var foundryAgentConsumerRoleId = 'eed3b665-ab3a-47b6-8f48-c9382fb1dad6'
var backendName = 'enterprise-foundry-agent-${uniqueString(enterpriseAgentName)}'
var apiName = 'enterprise-foundry-agent-${uniqueString(apiPath)}'
var directA2aBaseUrl = '${enterpriseProjectEndpoint}/agents/${enterpriseAgentName}/endpoint/protocols/a2a'
var publicA2aBaseUrl = '${apimService.properties.gatewayUrl}/${apiPath}'
// Foundry Agent Service resolves the agent card with urljoin semantics, which DROPS the last
// path segment when the base has no trailing slash (…/enterprise-specialist would resolve the
// card at …/enterprise-agents/.well-known/agent-card.json and 404). Discovery clients must use
// the trailing-slash form; the JSON-RPC runtime URL stays unslashed.
var publicA2aDiscoveryBaseUrl = '${publicA2aBaseUrl}/'
var allCallerObjectIds = union(allowedCallerObjectIds, [
  consumerProject.identity.principalId
])
var callerOidValues = join(map(allCallerObjectIds, objectId => '<value>${objectId}</value>'), '')
var validateCallerXml = '<validate-azure-ad-token tenant-id="${subscription().tenantId}" header-name="Authorization" failed-validation-httpcode="401" failed-validation-error-message="Unauthorized: an approved Microsoft Entra identity is required."><audiences><audience>${inboundAudience}</audience><audience>${inboundAudience}/</audience></audiences><required-claims><claim name="oid" match="any">${callerOidValues}</claim></required-claims></validate-azure-ad-token>'
var apiPolicyXml = '<policies><inbound><base />${validateCallerXml}<set-backend-service backend-id="${backendName}" /></inbound><backend><forward-request buffer-response="false" /></backend><outbound><base /></outbound><on-error><base /></on-error></policies>'

// Foundry v0.3 cards use top-level url. A2A v1 cards use supportedInterfaces. Rewrite both
// shapes so discovery and JSON-RPC invocation remain behind APIM.
// Two requirements make the card routes different from the JSON-RPC route:
//   1. buffer-response="true" — the API-scope backend streams for the runtime, and a streamed
//      body cannot be read in outbound.
//   2. Accept-Encoding: identity — Foundry gzips the card when the caller advertises gzip, and
//      a compressed body fails `As<JObject>()` with "message body is not a valid JSON".
var identityEncodingXml = '<set-header name="Accept-Encoding" exists-action="override"><value>identity</value></set-header>'
var cardRewriteBodyXml = '<set-body>@{ var card = context.Response.Body.As<JObject>(preserveContent: true); if (card["url"] != null) { card["url"] = "${publicA2aBaseUrl}"; } var supported = card["supportedInterfaces"] as JArray; if (supported != null) { foreach (var item in supported) { item["url"] = "${publicA2aBaseUrl}"; } } var additional = card["additionalInterfaces"] as JArray; if (additional != null) { foreach (var item in additional) { item["url"] = "${publicA2aBaseUrl}"; } } return card.ToString(); }</set-body>'
var cardRewriteXml = '<policies><inbound><base />${identityEncodingXml}</inbound><backend><forward-request buffer-response="true" /></backend><outbound><base />${cardRewriteBodyXml}</outbound><on-error><base /></on-error></policies>'
// The well-known aliases return the v0.3 card shape (top-level `url` + `protocolVersion`).
// Foundry Agent Service's A2A.AgentCard deserializer requires those properties and rejects the
// v1.0 `supportedInterfaces` shape. Modern a2a-sdk clients ask for /agentCard/v1.0 explicitly.
var wellKnownCardPolicyXml = '<policies><inbound><base />${identityEncodingXml}<rewrite-uri template="/agentCard/v0.3" /></inbound><backend><forward-request buffer-response="true" /></backend><outbound><base />${cardRewriteBodyXml}</outbound><on-error><base /></on-error></policies>'
// Legacy discovery path used by older A2A clients; same v0.3 shape.
var legacyCardPolicyXml = wellKnownCardPolicyXml

resource apimService 'Microsoft.ApiManagement/service@2024-06-01-preview' existing = {
  name: apimServiceName
}

resource enterpriseAccount 'Microsoft.CognitiveServices/accounts@2025-06-01' existing = {
  name: enterpriseFoundryAccountName
}

resource enterpriseProject 'Microsoft.CognitiveServices/accounts/projects@2025-04-01-preview' existing = {
  parent: enterpriseAccount
  name: enterpriseFoundryProjectName
}

resource consumerAccount 'Microsoft.CognitiveServices/accounts@2025-06-01' existing = {
  name: consumerFoundryAccountName
}

resource consumerProject 'Microsoft.CognitiveServices/accounts/projects@2025-04-01-preview' existing = {
  parent: consumerAccount
  name: consumerFoundryProjectName
}

// Least privilege: APIM may interact with agent endpoints in this enterprise project, but
// cannot create or modify agents.
resource apimAgentConsumerRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(enterpriseProject.id, apimService.id, foundryAgentConsumerRoleId)
  scope: enterpriseProject
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', foundryAgentConsumerRoleId)
    principalId: apimService.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource agentBackend 'Microsoft.ApiManagement/service/backends@2024-06-01-preview' = {
  name: backendName
  parent: apimService
  properties: {
    description: 'Foundry-hosted enterprise agent A2A endpoint (APIM MI authentication).'
    url: directA2aBaseUrl
    protocol: 'http'
    credentials: {
      #disable-next-line BCP037
      managedIdentity: {
        resource: foundryAudience
      }
    }
  }
  dependsOn: [
    apimAgentConsumerRole
  ]
}

resource agentApi 'Microsoft.ApiManagement/service/apis@2024-06-01-preview' = {
  name: apiName
  parent: apimService
  properties: {
    apiType: 'http'
    description: 'Enterprise Foundry agent exposed as a governed A2A API. Entra authentication on both hops; no keys.'
    displayName: 'Enterprise Foundry Agent - ${enterpriseAgentName}'
    path: apiPath
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

resource agentApiPolicy 'Microsoft.ApiManagement/service/apis/policies@2024-06-01-preview' = {
  name: 'policy'
  parent: agentApi
  properties: {
    format: 'rawxml'
    value: apiPolicyXml
  }
  dependsOn: [
    agentBackend
  ]
}

resource sendMessageOperation 'Microsoft.ApiManagement/service/apis/operations@2024-06-01-preview' = {
  name: 'a2a-jsonrpc'
  parent: agentApi
  properties: {
    displayName: 'A2A JSON-RPC runtime'
    method: 'POST'
    urlTemplate: '/'
  }
}

resource v1CardOperation 'Microsoft.ApiManagement/service/apis/operations@2024-06-01-preview' = {
  name: 'agent-card-v1'
  parent: agentApi
  properties: {
    displayName: 'Agent card (A2A v1.0)'
    method: 'GET'
    urlTemplate: '/agentCard/v1.0'
  }
}

resource v1CardPolicy 'Microsoft.ApiManagement/service/apis/operations/policies@2024-06-01-preview' = {
  name: 'policy'
  parent: v1CardOperation
  properties: {
    format: 'rawxml'
    value: cardRewriteXml
  }
}

resource v03CardOperation 'Microsoft.ApiManagement/service/apis/operations@2024-06-01-preview' = {
  name: 'agent-card-v03'
  parent: agentApi
  properties: {
    displayName: 'Agent card (A2A v0.3)'
    method: 'GET'
    urlTemplate: '/agentCard/v0.3'
  }
}

resource v03CardPolicy 'Microsoft.ApiManagement/service/apis/operations/policies@2024-06-01-preview' = {
  name: 'policy'
  parent: v03CardOperation
  properties: {
    format: 'rawxml'
    value: cardRewriteXml
  }
}

// Standard discovery alias for generic A2A clients. Foundry itself publishes agentCard/v1.0,
// so this operation rewrites the backend path before forwarding.
resource wellKnownCardOperation 'Microsoft.ApiManagement/service/apis/operations@2024-06-01-preview' = {
  name: 'agent-card-well-known'
  parent: agentApi
  properties: {
    displayName: 'Agent card (well-known alias)'
    method: 'GET'
    urlTemplate: '/.well-known/agent-card.json'
  }
}

resource wellKnownCardPolicy 'Microsoft.ApiManagement/service/apis/operations/policies@2024-06-01-preview' = {
  name: 'policy'
  parent: wellKnownCardOperation
  properties: {
    format: 'rawxml'
    value: wellKnownCardPolicyXml
  }
}

// Legacy discovery path. Foundry Agent Service resolves A2A cards here, and older A2A clients
// still use it, so both well-known spellings stay available through the gateway.
resource legacyCardOperation 'Microsoft.ApiManagement/service/apis/operations@2024-06-01-preview' = {
  name: 'agent-card-well-known-legacy'
  parent: agentApi
  properties: {
    displayName: 'Agent card (legacy well-known alias)'
    method: 'GET'
    urlTemplate: '/.well-known/agent.json'
  }
}

resource legacyCardPolicy 'Microsoft.ApiManagement/service/apis/operations/policies@2024-06-01-preview' = {
  name: 'policy'
  parent: legacyCardOperation
  properties: {
    format: 'rawxml'
    value: legacyCardPolicyXml
  }
}

// The consumer Foundry agent uses its project MI to reach APIM. The target carries a trailing
// slash so Foundry's urljoin-based card discovery stays under the agent's API path.
resource consumerA2aConnection 'Microsoft.CognitiveServices/accounts/projects/connections@2025-04-01-preview' = {
  parent: consumerProject
  name: 'enterprise-agent-apim'
  properties: {
    category: 'RemoteA2A'
    target: publicA2aDiscoveryBaseUrl
    #disable-next-line BCP036
    authType: 'ProjectManagedIdentity'
    audience: inboundAudience
    credentials: {}
    metadata: {
      ApiType: 'Azure'
    }
  }
}

output directA2aBaseUrl string = directA2aBaseUrl
output publicA2aBaseUrl string = publicA2aBaseUrl
output publicA2aDiscoveryBaseUrl string = publicA2aDiscoveryBaseUrl
output publicAgentCardUrl string = '${publicA2aBaseUrl}/.well-known/agent-card.json'
output consumerA2aConnectionId string = consumerA2aConnection.id
output consumerProjectPrincipalId string = consumerProject.identity.principalId
output apimBackendPrincipalId string = apimService.identity.principalId
