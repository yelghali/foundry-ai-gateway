// =====================================================================================
//  Client Foundry orchestrator — THREE dedicated client Foundry accounts, one per scenario
//  (companion to main.bicep; deploy AFTER main.bicep + litellm-foundry.bicep + a2a-agent)
//
//  The consumer side of the lab is split into one Foundry resource per gateway pattern, so
//  each account has a small, clear set of connections (the native AI Gateway integration is
//  configured at the Foundry *resource* level, which is why separate accounts are cleaner):
//
//    Scenario 1  client-foundry-sc1   CUSTOM (APIM)        subscription-key custom connection
//    Scenario 2  client-foundry-sc2   AI GATEWAY NATIVE    Foundry ApiManagement connection (MI-first, key fallback)
//    Scenario 3  client-foundry-sc3   AI GATEWAY BYO       LiteLLM ModelGateway connection
//
//  (Scenario 0 needs no Foundry — it is a local Microsoft Agent Framework app that reaches
//  the APIM passthrough APIs directly; see src/test/scenario0_local_apim.py.)
//
//  Every scenario account also hosts ONE small native gpt-4o-mini "driver" deployment, used
//  only to orchestrate the managed A2A tool (which 500s when the calling agent's model is a
//  gateway connection). The model and MCP legs deliberately go through the gateway.
// =====================================================================================

@description('Location for the client Foundry accounts.')
param location string = resourceGroup().location

@description('Base name shared by the three scenario accounts (a unique suffix is appended).')
param clientAccountBaseName string = 'client-foundry'

@description('Name of the existing APIM service (main.bicep output apimServiceName).')
param apimServiceName string

@description('Existing APIM subscription whose key the client presents to the gateway.')
param apimSubscriptionName string = 'subscription1'

@description('Path to the inference API in APIM (main.bicep inferenceAPIPath + endpoint path).')
param inferenceApiPath string = 'inference/openai'

@description('Azure OpenAI API version Foundry appends to inference calls through APIM.')
param inferenceApiVersion string = '2024-10-21'

@description('Path to the MS Learn MCP passthrough API in APIM.')
param learnMcpApiPath string = 'learn-mcp/mcp'

@description('Public FQDN of the existing LiteLLM Container App (litellm-foundry.bicep output gatewayFqdn).')
param litellmFqdn string

@description('LiteLLM master key (the Scenario 3 connection credential).')
@secure()
param litellmMasterKey string

@description('Path to the LiteLLM re-exposed MCP endpoint (trailing slash matters).')
param litellmMcpPath string = 'mcp/'

@description('Host root of the remote A2A agent that serves a spec-compliant agent card.')
param dummyA2aUrl string

@description('Names of the enterprise Foundry accounts (main.bicep) — used to grant the Scenario 1 MI data-plane access for the managed-identity probe.')
param enterpriseFoundryNames array = []

@description('Model (deployment) name exposed by the gateways.')
param modelName string = 'gpt-4o-mini'

@description('Underlying model version (metadata only).')
param modelVersion string = '2024-07-18'

@description('Capacity (K TPM) for each scenario account small native driver deployment.')
param driverModelCapacity int = 50

var resourceSuffix = uniqueString(subscription().id, resourceGroup().id)
var sc1AccountName = '${clientAccountBaseName}-sc1-${resourceSuffix}'
var sc2AccountName = '${clientAccountBaseName}-sc2-${resourceSuffix}'
var sc3AccountName = '${clientAccountBaseName}-sc3-${resourceSuffix}'

var enterpriseFoundryIds = [for n in enterpriseFoundryNames: resourceId('Microsoft.CognitiveServices/accounts', n)]

// ---------------- Scenario 1 — CUSTOM (APIM), subscription-key custom connection ----------------
module sc1 'client-foundry-sc1.bicep' = {
  name: 'client-foundry-sc1'
  params: {
    location: location
    accountName: sc1AccountName
    apimServiceName: apimServiceName
    apimSubscriptionName: apimSubscriptionName
    inferenceApiPath: inferenceApiPath
    learnMcpApiPath: learnMcpApiPath
    dummyA2aUrl: dummyA2aUrl
    enterpriseFoundryIds: enterpriseFoundryIds
    modelName: modelName
    modelVersion: modelVersion
    driverModelCapacity: driverModelCapacity
  }
}

// ---------------- Scenario 2 — AI GATEWAY NATIVE (APIM) ----------------
module sc2 'client-foundry-sc2.bicep' = {
  name: 'client-foundry-sc2'
  params: {
    location: location
    accountName: sc2AccountName
    apimServiceName: apimServiceName
    apimSubscriptionName: apimSubscriptionName
    inferenceApiPath: inferenceApiPath
    inferenceApiVersion: inferenceApiVersion
    learnMcpApiPath: learnMcpApiPath
    dummyA2aUrl: dummyA2aUrl
    enterpriseFoundryIds: enterpriseFoundryIds
    modelName: modelName
    modelVersion: modelVersion
    driverModelCapacity: driverModelCapacity
  }
}

// ---------------- Scenario 3 — AI GATEWAY BYO (LiteLLM) ----------------
module sc3 'client-foundry-sc3.bicep' = {
  name: 'client-foundry-sc3'
  params: {
    location: location
    accountName: sc3AccountName
    litellmFqdn: litellmFqdn
    litellmMasterKey: litellmMasterKey
    litellmMcpPath: litellmMcpPath
    dummyA2aUrl: dummyA2aUrl
    enterpriseFoundryIds: enterpriseFoundryIds
    modelName: modelName
    modelVersion: modelVersion
    driverModelCapacity: driverModelCapacity
  }
}

// ---------------- OUTPUTS (per scenario) ----------------
output sc1AccountName string = sc1.outputs.accountName
output sc1ProjectEndpoint string = sc1.outputs.projectEndpoint
output sc1DriverModelDeploymentName string = sc1.outputs.driverModelDeploymentName
output sc1CustomKeyModelDeploymentName string = sc1.outputs.customKeyModelDeploymentName
output sc1McpApimConnectionId string = sc1.outputs.mcpApimConnectionId
output sc1A2aDirectConnectionId string = sc1.outputs.a2aDirectConnectionId
output sc1AccountPrincipalId string = sc1.outputs.accountPrincipalId

output sc2AccountName string = sc2.outputs.accountName
output sc2ProjectEndpoint string = sc2.outputs.projectEndpoint
output sc2DriverModelDeploymentName string = sc2.outputs.driverModelDeploymentName
output sc2ApimModelDeploymentName string = sc2.outputs.apimModelDeploymentName
output sc2ApimMiModelDeploymentName string = sc2.outputs.apimMiModelDeploymentName
output sc2McpApimConnectionId string = sc2.outputs.mcpApimConnectionId
output sc2A2aDirectConnectionId string = sc2.outputs.a2aDirectConnectionId

output sc3AccountName string = sc3.outputs.accountName
output sc3ProjectEndpoint string = sc3.outputs.projectEndpoint
output sc3DriverModelDeploymentName string = sc3.outputs.driverModelDeploymentName
output sc3LitellmModelDeploymentName string = sc3.outputs.litellmModelDeploymentName
output sc3McpLitellmConnectionId string = sc3.outputs.mcpLitellmConnectionId
output sc3A2aDirectConnectionId string = sc3.outputs.a2aDirectConnectionId
