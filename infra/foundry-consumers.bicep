// Foundry resources for the supported two-consumer workshop path.
// client-foundry-sc1 is the Toolbox publisher; client-foundry-sc2 is the hosted app.

@description('Deployment location for both Foundry resources.')
param location string = resourceGroup().location

@description('Existing enterprise APIM service name.')
param apimServiceName string

@description('Foundry account that publishes the Toolbox.')
param toolboxPublisherAccountName string

@description('Project that publishes the Toolbox.')
param toolboxPublisherProjectName string = 'aigateway-sc1'

@description('Foundry account that hosts the consuming prompt agent.')
param appFoundryAccountName string

@description('Project that hosts the consuming prompt agent.')
param appFoundryProjectName string = 'aigateway-sc2'

@description('Model used by the app project as a native orchestration fallback for preview tool combinations.')
param driverModelName string = 'gpt-4o-mini'

@description('Version of the native driver model.')
param driverModelVersion string = '2024-07-18'

@description('Capacity in thousands of tokens per minute for the native driver.')
param driverModelCapacity int = 30

@description('Create the ownership-bound ApiManagement model connection. Set false on reruns after it exists.')
param createModelConnection bool = true

@description('Audience requested by the app project managed identity when calling APIM.')
param inboundAudience string = 'https://cognitiveservices.azure.com'

var apiVersion = '2024-10-21'
var modelConnectionName = 'apim-gateway-mi'
var modelTarget = '${apimService.properties.gatewayUrl}/inference-mi/openai'
var modelMetadata = '[{"name":"${driverModelName}","properties":{"model":{"name":"${driverModelName}","version":"${driverModelVersion}","format":"OpenAI"}}}]'
var modelConnectionId = '${appProject.id}/connections/${modelConnectionName}'

resource apimService 'Microsoft.ApiManagement/service@2024-06-01-preview' existing = {
  name: apimServiceName
}

resource toolboxPublisher 'Microsoft.CognitiveServices/accounts@2025-06-01' = {
  name: toolboxPublisherAccountName
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  kind: 'AIServices'
  sku: {
    name: 'S0'
  }
  properties: {
    allowProjectManagement: true
    customSubDomainName: toLower(toolboxPublisherAccountName)
    disableLocalAuth: true
    publicNetworkAccess: 'Enabled'
  }
}

resource toolboxProject 'Microsoft.CognitiveServices/accounts/projects@2025-04-01-preview' = {
  #disable-next-line BCP334
  parent: toolboxPublisher
  name: toolboxPublisherProjectName
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {}
}

resource appFoundry 'Microsoft.CognitiveServices/accounts@2025-06-01' = {
  name: appFoundryAccountName
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  kind: 'AIServices'
  sku: {
    name: 'S0'
  }
  properties: {
    allowProjectManagement: true
    customSubDomainName: toLower(appFoundryAccountName)
    disableLocalAuth: true
    publicNetworkAccess: 'Enabled'
  }
}

resource appProject 'Microsoft.CognitiveServices/accounts/projects@2025-04-01-preview' = {
  #disable-next-line BCP334
  parent: appFoundry
  name: appFoundryProjectName
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {}
}

resource driverModel 'Microsoft.CognitiveServices/accounts/deployments@2025-06-01' = {
  parent: appFoundry
  name: driverModelName
  sku: {
    name: 'GlobalStandard'
    capacity: driverModelCapacity
  }
  properties: {
    model: {
      format: 'OpenAI'
      name: driverModelName
      version: driverModelVersion
    }
  }
}

resource apimModelConnection 'Microsoft.CognitiveServices/accounts/projects/connections@2025-04-01-preview' = if (createModelConnection) {
  parent: appProject
  name: modelConnectionName
  properties: {
    category: 'ApiManagement'
    target: modelTarget
    #disable-next-line BCP036
    authType: 'ProjectManagedIdentity'
    audience: inboundAudience
    credentials: {}
    metadata: {
      models: modelMetadata
      deploymentInPath: 'true'
      inferenceAPIVersion: apiVersion
    }
  }
}

output toolboxPublisherAccountName string = toolboxPublisher.name
output toolboxProjectEndpoint string = '${replace(toolboxPublisher.properties.endpoint, '.cognitiveservices.azure.com', '.services.ai.azure.com')}api/projects/${toolboxProject.name}'
output toolboxProjectPrincipalId string = toolboxProject.identity.principalId
output appFoundryAccountName string = appFoundry.name
output appProjectEndpoint string = '${replace(appFoundry.properties.endpoint, '.cognitiveservices.azure.com', '.services.ai.azure.com')}api/projects/${appProject.name}'
output appProjectPrincipalId string = appProject.identity.principalId
output appDriverModel string = driverModel.name
output appModel string = '${modelConnectionName}/${driverModelName}'
output appModelConnectionId string = modelConnectionId