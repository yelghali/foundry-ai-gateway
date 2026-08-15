// Optional BYOM scenario for the existing Foundry app project.
// LiteLLM reaches private Foundry model backends with managed identity. Foundry
// reaches LiteLLM with a bearer credential because ModelGateway currently
// supports API key or OAuth 2.0, not ProjectManagedIdentity.

@description('Existing Foundry account that hosts the workshop app project.')
param appFoundryAccountName string

@description('Existing Foundry app project.')
param appFoundryProjectName string = 'aigateway-sc2'

@description('LiteLLM base URL without a trailing slash.')
param litellmBaseUrl string

@description('LiteLLM bearer key stored in Foundry connections and the A2A shim secret.')
@secure()
param litellmApiKey string

@description('Static model exposed through the ModelGateway connection.')
param modelName string = 'gpt-5.1'

@description('Underlying model version used as Foundry connection metadata.')
param modelVersion string = '2025-11-13'

@description('ID of the agent registered in the LiteLLM A2A Agent Gateway.')
param a2aAgentId string

@description('Non-secret marker that forces the A2A shim to reload rotated credentials.')
param credentialRevision string

var suffix = uniqueString(resourceGroup().id)
var shimAppName = 'ca-a2a-litellm-${suffix}'
var agentCode = loadTextContent('../src/a2a/dummy_agent.py')
var agentCodeHash = uniqueString(agentCode)
var modelConnectionName = 'litellm-gateway'
var mcpConnectionName = 'app-mcp-via-litellm'
var a2aConnectionName = 'app-a2a-via-litellm'
var modelMetadata = '[{"name":"${modelName}","properties":{"model":{"name":"${modelName}","version":"${modelVersion}","format":"OpenAI"}}}]'
var authConfig = '{"type":"api_key","name":"Authorization","format":"Bearer {api_key}"}'
var mcpUrl = '${litellmBaseUrl}/mcp/'
var a2aGatewayUrl = '${litellmBaseUrl}/a2a/${a2aAgentId}'
var modelConnectionId = '${appFoundry.id}/connections/${modelConnectionName}'
var mcpConnectionId = '${appProject.id}/connections/${mcpConnectionName}'
var a2aConnectionId = '${appProject.id}/connections/${a2aConnectionName}'

resource appFoundry 'Microsoft.CognitiveServices/accounts@2025-06-01' existing = {
  name: appFoundryAccountName
}

resource appProject 'Microsoft.CognitiveServices/accounts/projects@2025-04-01-preview' existing = {
  parent: appFoundry
  name: appFoundryProjectName
}

resource managedEnv 'Microsoft.App/managedEnvironments@2024-03-01' existing = {
  name: 'cae-a2a-${suffix}'
}

resource modelGatewayConnection 'Microsoft.CognitiveServices/accounts/connections@2025-04-01-preview' = {
  parent: appFoundry
  name: modelConnectionName
  properties: {
    category: 'ModelGateway'
    target: '${litellmBaseUrl}/v1'
    authType: 'ApiKey'
    credentials: {
      key: litellmApiKey
    }
    metadata: {
      models: modelMetadata
      deploymentInPath: 'false'
      authConfig: authConfig
    }
  }
}

resource mcpConnection 'Microsoft.CognitiveServices/accounts/projects/connections@2025-04-01-preview' = {
  parent: appProject
  name: mcpConnectionName
  properties: {
    category: 'CustomKeys'
    target: mcpUrl
    authType: 'CustomKeys'
    credentials: {
      keys: {
        Authorization: 'Bearer ${litellmApiKey}'
      }
    }
    metadata: {}
  }
}

// Foundry resolves A2A cards at the connection host root, while LiteLLM exposes
// each card below /a2a/{agent}. This authenticated shim serves the root card and
// forwards JSON-RPC to LiteLLM with the same bearer credential.
resource shimApp 'Microsoft.App/containerApps@2024-03-01' = {
  name: shimAppName
  location: resourceGroup().location
  properties: {
    managedEnvironmentId: managedEnv.id
    configuration: {
      ingress: {
        external: true
        targetPort: 8080
        transport: 'auto'
      }
      secrets: [
        {
          name: 'agent-code'
          #disable-next-line use-secure-value-for-secure-inputs
          value: agentCode
        }
        {
          name: 'gateway-auth'
          #disable-next-line use-secure-value-for-secure-inputs
          value: 'Bearer ${litellmApiKey}'
        }
      ]
    }
    template: {
      containers: [
        {
          name: 'a2a-litellm-shim'
          image: 'python:3.12-slim'
          command: [
            'python'
            '/app/dummy_agent.py'
          ]
          resources: {
            cpu: json('0.5')
            memory: '1Gi'
          }
          env: [
            {
              name: 'PORT'
              value: '8080'
            }
            {
              name: 'A2A_PUBLIC_URL'
              value: 'https://${shimAppName}.${managedEnv.properties.defaultDomain}/'
            }
            {
              name: 'A2A_FORWARD_URL'
              value: a2aGatewayUrl
            }
            {
              name: 'A2A_FORWARD_AUTH'
              secretRef: 'gateway-auth'
            }
            {
              name: 'A2A_INBOUND_AUTH'
              secretRef: 'gateway-auth'
            }
            {
              name: 'A2A_CODE_SHA256'
              value: agentCodeHash
            }
            {
              name: 'A2A_CREDENTIAL_REVISION'
              value: credentialRevision
            }
          ]
          volumeMounts: [
            {
              volumeName: 'code'
              mountPath: '/app'
            }
          ]
        }
      ]
      scale: {
        minReplicas: 1
        maxReplicas: 1
      }
      volumes: [
        {
          name: 'code'
          storageType: 'Secret'
          secrets: [
            {
              secretRef: 'agent-code'
              path: 'dummy_agent.py'
            }
          ]
        }
      ]
    }
  }
}

resource a2aConnection 'Microsoft.CognitiveServices/accounts/projects/connections@2025-04-01-preview' = {
  parent: appProject
  name: a2aConnectionName
  properties: {
    category: 'RemoteA2A'
    target: 'https://${shimApp.properties.configuration.ingress.fqdn}/'
    authType: 'CustomKeys'
    credentials: {
      keys: {
        Authorization: 'Bearer ${litellmApiKey}'
      }
    }
    metadata: {}
  }
}

output litellmBaseUrl string = litellmBaseUrl
output litellmModel string = '${modelConnectionName}/${modelName}'
output litellmModelConnectionId string = modelConnectionId
output litellmMcpUrl string = mcpUrl
output litellmMcpConnectionId string = mcpConnectionId
output litellmA2aGatewayUrl string = a2aGatewayUrl
output litellmA2aShimUrl string = 'https://${shimApp.properties.configuration.ingress.fqdn}/'
output litellmA2aConnectionId string = a2aConnectionId
