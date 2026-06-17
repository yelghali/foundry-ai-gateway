// =====================================================================================
//  Dummy A2A agent behind APIM (companion to main.bicep; deploy AFTER main.bicep)
//
//  Deploys:
//    - A Log Analytics workspace + Container Apps managed environment
//    - A tiny stdlib-only A2A agent (src/a2a/dummy_agent.py) on Azure Container Apps,
//      run inside a stock python:3.12-slim image (no pip install) with the code mounted
//      from a secret volume — public HTTPS ingress so APIM (cloud) can reach it.
//    - An APIM passthrough API ('dummy-a2a') so the gateway governs *A2A agent* traffic
//      the same way it governs model + MCP traffic: agents call {gateway}/dummy-a2a with
//      the api-key header; APIM proxies the A2A JSON-RPC + agent-card to the Container App.
//
//  Why a public Container App? APIM (and Foundry Agent Service) run in the cloud and must
//  reach the agent over HTTPS — they cannot call an A2A server on localhost.
// =====================================================================================

// ------------------
//    PARAMETERS
// ------------------

@description('Location for the Container Apps + Log Analytics resources.')
param location string = resourceGroup().location

@description('Name of the EXISTING APIM service deployed by main.bicep (output apimServiceName).')
param apimServiceName string

@description('Container image used to run the stdlib A2A agent (no extra packages needed).')
param agentImage string = 'python:3.12-slim'

@description('Port the dummy agent listens on inside the container.')
param agentPort int = 8080

// ------------------
//    VARIABLES
// ------------------

var suffix = uniqueString(resourceGroup().id)

// ------------------
//    EXISTING APIM
// ------------------

resource apimService 'Microsoft.ApiManagement/service@2024-06-01-preview' existing = {
  name: apimServiceName
}

// ------------------
//    CONTAINER APPS ENVIRONMENT
// ------------------

resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: 'log-a2a-${suffix}'
  location: location
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
  }
}

resource managedEnv 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: 'cae-a2a-${suffix}'
  location: location
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logAnalytics.properties.customerId
        sharedKey: logAnalytics.listKeys().primarySharedKey
      }
    }
  }
}

// ------------------
//    DUMMY A2A AGENT CONTAINER APP
// ------------------

resource a2aApp 'Microsoft.App/containerApps@2024-03-01' = {
  name: 'ca-a2a-dummy-${suffix}'
  location: location
  properties: {
    managedEnvironmentId: managedEnv.id
    configuration: {
      ingress: {
        external: true
        targetPort: agentPort
        transport: 'auto'
      }
      secrets: [
        {
          name: 'agent-code'
          value: loadTextContent('../src/a2a/dummy_agent.py')
        }
      ]
    }
    template: {
      containers: [
        {
          name: 'a2a-dummy'
          image: agentImage
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
              value: '${agentPort}'
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

// ------------------
//    APIM A2A PASSTHROUGH API
// ------------------
// Exposes the dummy A2A agent THROUGH APIM. Clients call {gateway}/dummy-a2a with the
// api-key header; APIM forwards the A2A JSON-RPC (message/send) and the agent card to the
// Container App.

resource a2aBackend 'Microsoft.ApiManagement/service/backends@2024-06-01-preview' = {
  name: 'dummy-a2a'
  parent: apimService
  properties: {
    description: 'Dummy A2A agent (Azure Container App)'
    url: 'https://${a2aApp.properties.configuration.ingress.fqdn}'
    protocol: 'http'
  }
}

resource a2aApi 'Microsoft.ApiManagement/service/apis@2024-06-01-preview' = {
  name: 'dummy-a2a'
  parent: apimService
  properties: {
    apiType: 'http'
    description: 'Dummy A2A agent, proxied through APIM (governs agent-to-agent traffic).'
    displayName: 'Dummy A2A Agent'
    path: 'dummy-a2a'
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

resource a2aApiPolicy 'Microsoft.ApiManagement/service/apis/policies@2024-06-01-preview' = {
  name: 'policy'
  parent: a2aApi
  properties: {
    format: 'rawxml'
    value: '<policies><inbound><base /><set-backend-service backend-id="dummy-a2a" /></inbound><backend><forward-request buffer-response="false" /></backend><outbound><base /></outbound><on-error><base /></on-error></policies>'
  }
  dependsOn: [
    a2aBackend
  ]
}

// A2A JSON-RPC requests (message/send) are POSTed to the agent root.
resource a2aPostOperation 'Microsoft.ApiManagement/service/apis/operations@2024-06-01-preview' = {
  name: 'a2a-message-send'
  parent: a2aApi
  properties: {
    displayName: 'A2A request (JSON-RPC message/send)'
    method: 'POST'
    urlTemplate: '/'
  }
}

// Agent discovery (AgentCard).
resource a2aCardOperation 'Microsoft.ApiManagement/service/apis/operations@2024-06-01-preview' = {
  name: 'a2a-agent-card'
  parent: a2aApi
  properties: {
    displayName: 'A2A agent card (discovery)'
    method: 'GET'
    urlTemplate: '/.well-known/agent-card.json'
  }
}

resource a2aLegacyCardOperation 'Microsoft.ApiManagement/service/apis/operations@2024-06-01-preview' = {
  name: 'a2a-agent-json'
  parent: a2aApi
  properties: {
    displayName: 'A2A agent card (legacy path)'
    method: 'GET'
    urlTemplate: '/.well-known/agent.json'
  }
}

// ------------------
//    OUTPUTS
// ------------------

@description('Direct HTTPS URL of the dummy A2A agent Container App (bypasses the gateway).')
output a2aAgentDirectUrl string = 'https://${a2aApp.properties.configuration.ingress.fqdn}'

@description('Dummy A2A agent proxied through APIM. POST A2A JSON-RPC here with the api-key header.')
output a2aAgentApimUrl string = '${apimService.properties.gatewayUrl}/dummy-a2a'
