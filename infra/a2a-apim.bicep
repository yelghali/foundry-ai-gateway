// =====================================================================================
//  A2A dummy agent THROUGH APIM (additive; deploy AFTER main.bicep + a2a-agent.bicep +
//  deploy-client-foundry.ps1). Does NOT modify any existing resource.
//
//  Why this exists
//  ---------------
//  The lab's Scenario 1/2/3 A2A leg reaches the dummy specialist *directly* at its
//  Container App host root, because a Foundry RemoteA2A connection resolves the agent
//  card and then POSTs message/send to the card's own `url` field — and the dummy
//  agent advertises its ACA URL there.
//
//  Foundry's RemoteA2A card resolver uses urljoin semantics: it fetches the agent card
//  at the connection target's HOST ROOT ({host}/.well-known/agent-card.json), ignoring
//  any sub-path on the target. So to route A2A through APIM we must serve the card at
//  the APIM host root AND make that card advertise a `url` that points back through APIM.
//
//  This template does both, additively:
//    - A NEW message API 'dummy-a2a-apim' (path dummy-a2a-apim) that reuses the EXISTING
//      'dummy-a2a' backend (the same Container App) — no new compute. This is where
//      message/send (JSON-RPC) flows through APIM.
//    - A NEW root API 'dummy-a2a-card' (path '') that serves GET /.well-known/agent-card.json
//      from the same backend, with an OUTBOUND policy that rewrites the card's `url` to
//      {gateway}/dummy-a2a-apim. Because it lives at the host root, the RemoteA2A resolver
//      finds it with the default agent-card path.
//    - A NEW RemoteA2A connection 'dummy-a2a-apim' on the Scenario 1 client account whose
//      target is the APIM HOST ROOT and which carries the APIM subscription key as the
//      api-key header (used for both the card fetch and message/send).
//
//  Existing APIs ('dummy-a2a'), backends and connections ('dummy-a2a-direct') are left
//  untouched, so every current scenario keeps working exactly as before.
// =====================================================================================

// ------------------
//    PARAMETERS
// ------------------

@description('Name of the EXISTING APIM service (main.bicep output apimServiceName).')
param apimServiceName string

@description('Name of the EXISTING APIM subscription that holds the gateway key.')
param apimSubscriptionName string = 'subscription1'

@description('Name of the EXISTING Scenario 1 client Foundry account that gets the new connection.')
param sc1AccountName string

@description('Name of the EXISTING dummy A2A backend in APIM (created by a2a-agent.bicep).')
param a2aBackendId string = 'dummy-a2a'

@description('Path of the NEW through-APIM A2A message API.')
param apiPath string = 'dummy-a2a-apim'

// ------------------
//    EXISTING RESOURCES (read-only references)
// ------------------

resource apimService 'Microsoft.ApiManagement/service@2024-06-01-preview' existing = {
  name: apimServiceName
}

resource apimSubscription 'Microsoft.ApiManagement/service/subscriptions@2024-06-01-preview' existing = {
  parent: apimService
  name: apimSubscriptionName
}

resource sc1Account 'Microsoft.CognitiveServices/accounts@2025-06-01' existing = {
  name: sc1AccountName
}

var gatewayUrl = apimService.properties.gatewayUrl
// Where the rewritten agent card tells callers to POST message/send (through APIM).
var a2aMessageUrl = '${gatewayUrl}/${apiPath}'

var backendPolicyXml = '<policies><inbound><base /><set-backend-service backend-id="${a2aBackendId}" /></inbound><backend><forward-request buffer-response="false" /></backend><outbound><base /></outbound><on-error><base /></on-error></policies>'

// Outbound policy for the root card operations: rewrite the AgentCard's `url` to the APIM
// message endpoint, so the calling agent posts message/send back through APIM.
var cardPolicyXml = '<policies><inbound><base /><set-backend-service backend-id="${a2aBackendId}" /></inbound><backend><forward-request buffer-response="false" /></backend><outbound><base /><set-body>@{ var card = context.Response.Body.As<JObject>(preserveContent: true); card["url"] = "${a2aMessageUrl}"; return card.ToString(); }</set-body></outbound><on-error><base /></on-error></policies>'

// ------------------
//    NEW MESSAGE API: dummy-a2a-apim  (POST / -> JSON-RPC message/send)
// ------------------

resource a2aApimApi 'Microsoft.ApiManagement/service/apis@2024-06-01-preview' = {
  name: apiPath
  parent: apimService
  properties: {
    apiType: 'http'
    description: 'Dummy A2A agent message endpoint, proxied through APIM (message/send flows through the gateway).'
    displayName: 'Dummy A2A Agent — message (through APIM)'
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

// API-level policy: route everything to the existing dummy-a2a backend (the Container App).
resource a2aApimApiPolicy 'Microsoft.ApiManagement/service/apis/policies@2024-06-01-preview' = {
  name: 'policy'
  parent: a2aApimApi
  properties: {
    format: 'rawxml'
    value: backendPolicyXml
  }
}

// A2A JSON-RPC requests (message/send) POSTed to the agent root.
resource a2aPostOperation 'Microsoft.ApiManagement/service/apis/operations@2024-06-01-preview' = {
  name: 'a2a-message-send'
  parent: a2aApimApi
  properties: {
    displayName: 'A2A request (JSON-RPC message/send)'
    method: 'POST'
    urlTemplate: '/'
  }
}

// ------------------
//    NEW ROOT CARD API: dummy-a2a-card  (path '' -> GET /.well-known/agent-card.json)
// ------------------
// Served at the APIM host root so Foundry's RemoteA2A resolver (urljoin against the host)
// finds it with the default agent-card path. The card url is rewritten to the message API.

resource a2aCardApi 'Microsoft.ApiManagement/service/apis@2024-06-01-preview' = {
  name: 'dummy-a2a-card'
  parent: apimService
  properties: {
    apiType: 'http'
    description: 'Dummy A2A agent card served at the APIM host root (url rewritten to the through-APIM message endpoint).'
    displayName: 'Dummy A2A Agent — card (host root)'
    path: ''
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

resource a2aCardApiPolicy 'Microsoft.ApiManagement/service/apis/policies@2024-06-01-preview' = {
  name: 'policy'
  parent: a2aCardApi
  properties: {
    format: 'rawxml'
    value: cardPolicyXml
  }
}

resource a2aCardOperation 'Microsoft.ApiManagement/service/apis/operations@2024-06-01-preview' = {
  name: 'a2a-agent-card'
  parent: a2aCardApi
  properties: {
    displayName: 'A2A agent card (discovery)'
    method: 'GET'
    urlTemplate: '/.well-known/agent-card.json'
  }
}

resource a2aLegacyCardOperation 'Microsoft.ApiManagement/service/apis/operations@2024-06-01-preview' = {
  name: 'a2a-agent-json'
  parent: a2aCardApi
  properties: {
    displayName: 'A2A agent card (legacy path)'
    method: 'GET'
    urlTemplate: '/.well-known/agent.json'
  }
}

// ------------------
//    NEW RemoteA2A CONNECTION on the Scenario 1 client account
// ------------------
// Target is the APIM HOST ROOT (so card discovery resolves to the root card API). Carries
// the APIM subscription key as the api-key header for both the card fetch and message/send.

resource a2aApimConnection 'Microsoft.CognitiveServices/accounts/connections@2025-04-01-preview' = {
  parent: sc1Account
  name: 'dummy-a2a-apim'
  properties: {
    category: 'RemoteA2A'
    target: gatewayUrl
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
//    OUTPUTS
// ------------------

@description('Base URL the RemoteA2A connection/tool uses (APIM host root; default card path resolves to the root card API).')
output a2aApimUrl string = gatewayUrl

@description('Through-APIM message endpoint the rewritten card advertises (where message/send flows).')
output a2aApimMessageUrl string = a2aMessageUrl

@description('Resource id of the new RemoteA2A connection on the Scenario 1 client account.')
output sc1A2aApimConnectionId string = a2aApimConnection.id
