// =====================================================================================
//  Bring Your Own Gateway INTO Foundry — APIM as a Foundry "API Management" connection
//  (companion to main.bicep; deploy AFTER main.bicep)
//
//  This is the *APIM* variant of Part 5. Instead of a self-hosted LiteLLM proxy
//  (category: ModelGateway), it registers the APIM instance you already built in
//  Parts 1–3 as a Foundry connection of category "ApiManagement", so Foundry Agent
//  Service routes agent model calls through your APIM gateway (and its backend pool,
//  load balancing, retries and policies).
//
//  Why APIM connection instead of ModelGateway?
//    - APIM connections give Foundry intelligent defaults for Azure-OpenAI-style
//      routes (/deployments/{name}/chat/completions) — no container to run.
//    - Reuses the existing APIM managed identity → Foundry backends, subscription
//      keys and policies you already have.
//
//  Deploys:
//    - A Foundry connection (category: ApiManagement) on the Foundry account,
//      pointing Foundry Agent Service at the APIM inference API, authenticated with
//      an existing APIM subscription key.
// =====================================================================================

// ------------------
//    PARAMETERS
// ------------------

@description('Name of the existing APIM service (main.bicep output apimServiceName).')
param apimServiceName string

@description('Name of an existing APIM subscription whose key Foundry presents to the gateway (main.bicep apimSubscriptionsConfig[].name).')
param apimSubscriptionName string = 'subscription1'

@description('The Foundry account that hosts the connection (the parent resource of the project). Defaults to the first account from main.bicep.')
param connectionAccountName string

@description('Path to the inference API in APIM (main.bicep inferenceAPIPath plus endpoint path). The default matches the main.bicep value of inference/openai.')
param inferenceApiPath string = 'inference/openai'

@description('Azure OpenAI API version Foundry appends to inference calls through APIM.')
param inferenceApiVersion string = '2024-10-21'

@description('Name of the Foundry API Management connection.')
param connectionName string = 'apim-gateway'

@description('Model deployment name as exposed by APIM (the {deployment-id} in /deployments/{deployment-id}/chat/completions).')
param modelName string = 'gpt-4o-mini'

@description('Underlying model version (metadata only).')
param modelVersion string = '2024-07-18'

// ------------------
//    VARIABLES
// ------------------

// Static model list registered on the connection (JSON string — Foundry requires
// complex metadata values to be serialized). "name" is the APIM deployment id.
var modelsMetadata = '[{"name":"${modelName}","properties":{"model":{"name":"${modelName}","version":"${modelVersion}","format":"OpenAI"}}}]'

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

resource connectionAccount 'Microsoft.CognitiveServices/accounts@2025-06-01' existing = {
  name: connectionAccountName
}

// ------------------
//    FOUNDRY API MANAGEMENT CONNECTION
// ------------------

resource apimConnection 'Microsoft.CognitiveServices/accounts/connections@2025-04-01-preview' = {
  parent: connectionAccount
  name: connectionName
  properties: {
    category: 'ApiManagement'
    // {gatewayUrl}/inference/openai  →  Foundry builds /deployments/{name}/chat/completions under it.
    target: '${apimService.properties.gatewayUrl}/${inferenceApiPath}'
    authType: 'ApiKey'
    credentials: {
      // APIM's default subscription-key header is "api-key", which is the APIM
      // connection default — no custom authConfig needed.
      key: apimSubscription.listSecrets().primaryKey
    }
    metadata: {
      // Static model discovery — no /deployments call needed.
      models: modelsMetadata
      // true => path-based routing: {target}/deployments/{deploymentName}/chat/completions.
      deploymentInPath: 'true'
      inferenceAPIVersion: inferenceApiVersion
    }
  }
}

// ------------------
//    OUTPUTS
// ------------------

output gatewayUrl string = '${apimService.properties.gatewayUrl}/${inferenceApiPath}'
output connectionName string = connectionName
output connectionAccount string = connectionAccountName
@description('Use this as FOUNDRY_MODEL_DEPLOYMENT_NAME for the agent: <connection>/<model>.')
output modelDeploymentName string = '${connectionName}/${modelName}'
