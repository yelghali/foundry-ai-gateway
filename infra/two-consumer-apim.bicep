// Repeatable APIM surfaces shared by a local MAF client and Foundry-hosted agents.

@description('Name of the existing enterprise APIM service.')
param apimServiceName string

@description('Foundry account that hosts the Toolbox and MCP-consuming agent.')
param toolboxFoundryAccountName string

@description('Foundry project that hosts the Toolbox and MCP-consuming agent.')
param toolboxFoundryProjectName string = 'aigateway-sc1'

@description('Project endpoint without a trailing slash.')
param toolboxProjectEndpoint string

@description('Foundry account that owns the ApiManagement model connection.')
param modelConsumerFoundryAccountName string

@description('Foundry project that owns the ApiManagement model connection.')
param modelConsumerFoundryProjectName string = 'aigateway-sc2'

@description('Additional Entra object IDs allowed to call APIM, such as a local MAF developer or workload identity.')
param allowedCallerObjectIds array = []

@description('Entra audience accepted by the APIM APIs.')
param inboundAudience string = 'https://cognitiveservices.azure.com'

@description('Name of the Foundry Toolbox published through APIM.')
param toolboxName string = 'scenario1-apim-toolbox'

@description('Public APIM path for the Toolbox MCP endpoint.')
param toolboxApiPath string = 'toolboxes/research'

@description('Create the Foundry project connection to the APIM Toolbox endpoint. Set false after the connection exists because Foundry connections are ownership-bound.')
param createToolboxConnection bool = true

@description('Create the project-scoped MCP connection used inside the Toolbox. Set false after the connection exists because Foundry connections are ownership-bound.')
param createMcpConnection bool = true

@description('Create the raw MCP connection in the Foundry consumer project.')
param createAppMcpConnection bool = true

@description('Create the Toolbox connection in the Foundry consumer project.')
param createAppToolboxConnection bool = true

var foundryAudience = 'https://ai.azure.com'
var foundryUserRoleId = '53ca6127-db72-4b80-b1b0-d745d6d5456d'
var modelBackendPoolName = 'inference-backend-pool'
var allCallerObjectIds = union(allowedCallerObjectIds, [
  toolboxProject.identity.principalId
  modelConsumerProject.identity.principalId
])
var callerOidValues = join(map(allCallerObjectIds, objectId => '<value>${objectId}</value>'), '')
var callerAuthorizationXml = '<required-claims><claim name="oid" match="any">${callerOidValues}</claim></required-claims>'
var validateCallerXml = '<validate-azure-ad-token tenant-id="${subscription().tenantId}" header-name="Authorization" failed-validation-httpcode="401" failed-validation-error-message="Unauthorized: an approved Microsoft Entra identity is required."><audiences><audience>${inboundAudience}</audience><audience>${inboundAudience}/</audience></audiences>${callerAuthorizationXml}</validate-azure-ad-token>'
var modelPolicyXml = replace(replace(replace(loadTextContent('policy-mi.xml'), '{backend-id}', modelBackendPoolName), '{tenant-id}', subscription().tenantId), '{caller-authorization}', callerAuthorizationXml)
var mcpPolicyXml = '<policies><inbound><base />${validateCallerXml}<set-backend-service backend-id="mslearn-mcp" /><set-header name="Authorization" exists-action="delete" /></inbound><backend><forward-request buffer-response="false" /></backend><outbound><base /></outbound><on-error><base /></on-error></policies>'
var toolboxBackendName = 'foundry-toolbox-${uniqueString(toolboxFoundryAccountName, toolboxFoundryProjectName, toolboxName)}'
var toolboxTokenXml = '<authentication-managed-identity resource="${foundryAudience}" output-token-variable-name="toolbox-access-token" ignore-error="false" /><set-header name="Authorization" exists-action="override"><value>@("Bearer " + (string)context.Variables["toolbox-access-token"])</value></set-header>'
var toolboxPolicyXml = '<policies><inbound><base />${validateCallerXml}<set-backend-service backend-id="${toolboxBackendName}" /><set-query-parameter name="api-version" exists-action="override"><value>v1</value></set-query-parameter>${toolboxTokenXml}</inbound><backend><forward-request buffer-request-body="true" buffer-response="false" /></backend><outbound><base /></outbound><on-error><base /></on-error></policies>'
var publicToolboxMcpUrl = '${apimService.properties.gatewayUrl}/${toolboxApiPath}/mcp'
var toolboxConnectionId = '${toolboxProject.id}/connections/toolbox-via-apim'
var mcpConnectionId = '${toolboxProject.id}/connections/mcp-via-apim'
var appMcpConnectionId = '${modelConsumerProject.id}/connections/app-mcp-via-apim'
var appToolboxConnectionId = '${modelConsumerProject.id}/connections/app-toolbox-via-apim'

resource apimService 'Microsoft.ApiManagement/service@2024-06-01-preview' existing = {
  name: apimServiceName
}

resource toolboxAccount 'Microsoft.CognitiveServices/accounts@2025-06-01' existing = {
  name: toolboxFoundryAccountName
}

resource toolboxProject 'Microsoft.CognitiveServices/accounts/projects@2025-04-01-preview' existing = {
  parent: toolboxAccount
  name: toolboxFoundryProjectName
}

resource modelConsumerAccount 'Microsoft.CognitiveServices/accounts@2025-06-01' existing = {
  name: modelConsumerFoundryAccountName
}

resource modelConsumerProject 'Microsoft.CognitiveServices/accounts/projects@2025-04-01-preview' existing = {
  parent: modelConsumerAccount
  name: modelConsumerFoundryProjectName
}

// Tighten the existing keyless model API from tenant-wide authentication to an explicit
// caller allowlist shared by the two workshop consumers.
resource inferenceMiApi 'Microsoft.ApiManagement/service/apis@2024-06-01-preview' existing = {
  parent: apimService
  name: 'inference-mi-api'
}

resource inferenceMiApiPolicy 'Microsoft.ApiManagement/service/apis/policies@2024-06-01-preview' = {
  parent: inferenceMiApi
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: modelPolicyXml
  }
}

resource mcpApi 'Microsoft.ApiManagement/service/apis@2024-06-01-preview' = {
  parent: apimService
  name: 'mslearn-mcp-mi'
  properties: {
    apiType: 'http'
    description: 'Microsoft Learn MCP through APIM with an explicit Entra caller allowlist.'
    displayName: 'Microsoft Learn MCP (Entra)'
    path: 'learn-mcp-mi'
    protocols: [
      'https'
    ]
    subscriptionRequired: false
    type: 'http'
  }
}

resource mcpApiPolicy 'Microsoft.ApiManagement/service/apis/policies@2024-06-01-preview' = {
  parent: mcpApi
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: mcpPolicyXml
  }
}

resource mcpOperations 'Microsoft.ApiManagement/service/apis/operations@2024-06-01-preview' = [for method in [
  'POST'
  'GET'
  'DELETE'
]: {
  parent: mcpApi
  name: 'mcp-${toLower(method)}'
  properties: {
    displayName: 'MCP ${method}'
    method: method
    urlTemplate: '/mcp'
  }
}]

resource apimToolboxRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(toolboxProject.id, apimService.id, foundryUserRoleId)
  scope: toolboxProject
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', foundryUserRoleId)
    principalId: apimService.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource toolboxBackend 'Microsoft.ApiManagement/service/backends@2024-06-01-preview' = {
  parent: apimService
  name: toolboxBackendName
  properties: {
    description: 'Foundry Toolbox MCP endpoint authenticated with the APIM managed identity.'
    protocol: 'http'
    url: '${toolboxProjectEndpoint}/toolboxes/${toolboxName}'
  }
  dependsOn: [
    apimToolboxRole
  ]
}

resource toolboxApi 'Microsoft.ApiManagement/service/apis@2024-06-01-preview' = {
  parent: apimService
  name: 'foundry-toolbox-${uniqueString(toolboxApiPath)}'
  properties: {
    apiType: 'http'
    description: 'Foundry Toolbox published as a governed MCP endpoint through APIM.'
    displayName: 'Foundry Toolbox - ${toolboxName}'
    path: toolboxApiPath
    protocols: [
      'https'
    ]
    subscriptionRequired: false
    type: 'http'
  }
}

resource toolboxApiPolicy 'Microsoft.ApiManagement/service/apis/policies@2024-06-01-preview' = {
  parent: toolboxApi
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: toolboxPolicyXml
  }
  dependsOn: [
    toolboxBackend
  ]
}

resource toolboxOperations 'Microsoft.ApiManagement/service/apis/operations@2024-06-01-preview' = [for method in [
  'POST'
  'GET'
  'DELETE'
]: {
  parent: toolboxApi
  name: 'mcp-${toLower(method)}'
  properties: {
    displayName: 'Toolbox MCP ${method}'
    method: method
    urlTemplate: '/mcp'
  }
}]

resource toolboxApimConnection 'Microsoft.CognitiveServices/accounts/projects/connections@2025-04-01-preview' = if (createToolboxConnection) {
  parent: toolboxProject
  name: 'toolbox-via-apim'
  properties: {
    category: 'RemoteTool'
    target: publicToolboxMcpUrl
    #disable-next-line BCP036
    authType: 'ProjectManagedIdentity'
    audience: inboundAudience
    credentials: {}
    metadata: {}
  }
}

resource mcpApimConnection 'Microsoft.CognitiveServices/accounts/projects/connections@2025-04-01-preview' = if (createMcpConnection) {
  parent: toolboxProject
  name: 'mcp-via-apim'
  properties: {
    category: 'CustomKeys'
    target: '${apimService.properties.gatewayUrl}/learn-mcp-mi/mcp'
    #disable-next-line BCP036
    authType: 'ProjectManagedIdentity'
    audience: inboundAudience
    credentials: {}
    metadata: {}
  }
}

resource appMcpApimConnection 'Microsoft.CognitiveServices/accounts/projects/connections@2025-04-01-preview' = if (createAppMcpConnection) {
  parent: modelConsumerProject
  name: 'app-mcp-via-apim'
  properties: {
    category: 'CustomKeys'
    target: '${apimService.properties.gatewayUrl}/learn-mcp-mi/mcp'
    #disable-next-line BCP036
    authType: 'ProjectManagedIdentity'
    audience: inboundAudience
    credentials: {}
    metadata: {}
  }
}

resource appToolboxApimConnection 'Microsoft.CognitiveServices/accounts/projects/connections@2025-04-01-preview' = if (createAppToolboxConnection) {
  parent: modelConsumerProject
  name: 'app-toolbox-via-apim'
  properties: {
    category: 'RemoteTool'
    target: publicToolboxMcpUrl
    #disable-next-line BCP036
    authType: 'ProjectManagedIdentity'
    audience: inboundAudience
    credentials: {}
    metadata: {}
  }
}

output allowedCallerObjectIds array = allCallerObjectIds
output modelApiUrl string = '${apimService.properties.gatewayUrl}/inference-mi'
output mcpApiUrl string = '${apimService.properties.gatewayUrl}/learn-mcp-mi/mcp'
output toolboxApiUrl string = publicToolboxMcpUrl
output toolboxConnectionId string = toolboxConnectionId
output mcpConnectionId string = mcpConnectionId
output appMcpConnectionId string = appMcpConnectionId
output appToolboxConnectionId string = appToolboxConnectionId
output toolboxProjectPrincipalId string = toolboxProject.identity.principalId
output modelConsumerProjectPrincipalId string = modelConsumerProject.identity.principalId
output apimPrincipalId string = apimService.identity.principalId