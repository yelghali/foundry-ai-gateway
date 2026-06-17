// =====================================================================================
//  A2A dummy specialist THROUGH LiteLLM (additive; deploy AFTER a2a-agent.bicep +
//  litellm-foundry.bicep + deploy-client-foundry.ps1). Does NOT modify any existing
//  resource.
//
//  Why this exists
//  ---------------
//  LiteLLM's A2A "Agent Gateway" re-exposes a registered agent under a PATH
//  ({litellm}/a2a/dummy-specialist) and requires an Authorization: Bearer master key.
//  A managed Foundry RemoteA2A tool, however, (1) discovers the agent card at the
//  connection target's HOST ROOT, and (2) scopes the connection credential to that
//  target host. LiteLLM serves no host-root card and lives on a different host than the
//  client's connection target, so a managed Foundry agent cannot reach LiteLLM's A2A
//  endpoint directly.
//
//  This template bridges that gap with a tiny host-root SHIM, additively:
//    - A NEW Container App 'ca-a2a-lit-<suffix>' that runs the SAME stdlib
//      dummy agent (src/a2a/dummy_agent.py) in host-root SHIM mode: it serves the agent
//      card at its own host root (so Foundry can discover it) and, on message/send,
//      forwards the JSON-RPC call to the LiteLLM A2A endpoint with the Bearer key
//      injected (A2A_FORWARD_URL + A2A_FORWARD_AUTH). The agent-to-agent message leg
//      therefore flows THROUGH LiteLLM (governed + observable there).
//    - A NEW RemoteA2A connection 'dummy-a2a-litellm' on the Scenario 3 client account
//      whose target is the shim's host root (no client-side key needed — the shim holds
//      the LiteLLM credential).
//
//  The existing direct dummy agent, the LiteLLM proxy, and the 'dummy-a2a-direct'
//  connection are all left untouched, so every current scenario keeps working.
// =====================================================================================

// ------------------
//    PARAMETERS
// ------------------

@description('Location for the shim Container App (must match the existing A2A environment).')
param location string = resourceGroup().location

@description('Name of the EXISTING Scenario 3 client Foundry account that gets the new connection.')
param sc3AccountName string

@description('LiteLLM A2A endpoint the shim forwards message/send to, e.g. https://<litellm>/a2a/dummy-specialist')
param a2aLitellmEndpoint string

@description('LiteLLM master key the shim presents to the LiteLLM A2A gateway.')
@secure()
param litellmMasterKey string

@description('Container image used to run the stdlib A2A agent (no extra packages needed).')
param agentImage string = 'python:3.12-slim'

@description('Port the shim agent listens on inside the container.')
param agentPort int = 8080

// ------------------
//    VARIABLES
// ------------------

var suffix = uniqueString(resourceGroup().id)
var shimAppName = 'ca-a2a-lit-${suffix}'

// ------------------
//    EXISTING RESOURCES (read-only references)
// ------------------

// Reuse the Container Apps environment created by a2a-agent.bicep (no new env/compute plane).
resource managedEnv 'Microsoft.App/managedEnvironments@2024-03-01' existing = {
  name: 'cae-a2a-${suffix}'
}

resource sc3Account 'Microsoft.CognitiveServices/accounts@2025-06-01' existing = {
  name: sc3AccountName
}

// ------------------
//    SHIM CONTAINER APP (host-root card + forward message/send to LiteLLM)
// ------------------

resource shimApp 'Microsoft.App/containerApps@2024-03-01' = {
  name: shimAppName
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
        {
          name: 'forward-auth'
          value: 'Bearer ${litellmMasterKey}'
        }
      ]
    }
    template: {
      containers: [
        {
          name: 'a2a-dummy-litellm'
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
            {
              // Advertise THIS shim's own host root in the card so Foundry posts
              // message/send back here; the shim then forwards to LiteLLM.
              name: 'A2A_PUBLIC_URL'
              value: 'https://${shimAppName}.${managedEnv.properties.defaultDomain}'
            }
            {
              // Forward message/send to the LiteLLM A2A gateway (the governed leg).
              name: 'A2A_FORWARD_URL'
              value: a2aLitellmEndpoint
            }
            {
              // Authenticate to LiteLLM on the client's behalf.
              name: 'A2A_FORWARD_AUTH'
              secretRef: 'forward-auth'
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
//    NEW RemoteA2A CONNECTION on the Scenario 3 client account
// ------------------
// Target is the shim host root. No client-side key is needed because the shim injects
// the LiteLLM Bearer key on the forwarded message/send.

resource a2aLitellmConnection 'Microsoft.CognitiveServices/accounts/connections@2025-04-01-preview' = {
  parent: sc3Account
  name: 'dummy-a2a-litellm'
  properties: {
    category: 'RemoteA2A'
    target: 'https://${shimApp.properties.configuration.ingress.fqdn}'
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

@description('Host root of the shim the RemoteA2A connection targets (serves the agent card).')
output a2aLitellmUrl string = 'https://${shimApp.properties.configuration.ingress.fqdn}'

@description('LiteLLM A2A endpoint the shim forwards message/send to (the governed leg).')
output a2aLitellmEndpoint string = a2aLitellmEndpoint

@description('Resource id of the new RemoteA2A connection on the Scenario 3 client account.')
output sc3A2aLitellmConnectionId string = a2aLitellmConnection.id

