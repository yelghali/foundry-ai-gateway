// =====================================================================================
//  Bring Your Own Gateway INTO Foundry — LiteLLM as a Foundry "Model Gateway" connection
//  (companion to main.bicep; deploy AFTER main.bicep)
//
//  Deploys:
//    - A user-assigned managed identity granted "Cognitive Services User" on both
//      existing Foundry accounts (so LiteLLM authenticates with Entra ID, no keys)
//    - A Log Analytics workspace + Container Apps managed environment
//    - LiteLLM running on Azure Container Apps (public HTTPS ingress) with the
//      managed identity + automatic Azure AD token refresh
//    - A Foundry "Model Gateway" connection (category: ModelGateway) on the Foundry
//      account, pointing Foundry Agent Service at the LiteLLM endpoint
//
//  Why a public endpoint? Foundry Agent Service runs in the cloud and must reach the
//  gateway over HTTPS — it cannot call a LiteLLM proxy on localhost.
// =====================================================================================

// ------------------
//    PARAMETERS
// ------------------

@description('Location for the Container Apps + identity resources.')
param location string = resourceGroup().location

@description('The two existing Foundry account names (from main.bicep output foundryAccounts[*].name). The first is used for FOUNDRY1_API_BASE, the second for FOUNDRY2_API_BASE.')
param foundryAccountNames array

@description('Which Foundry account hosts the Model Gateway connection. Defaults to the first account.')
param connectionAccountName string = foundryAccountNames[0]

@description('Azure OpenAI API version used by LiteLLM to call the Foundry deployments.')
param apiVersion string = '2024-10-21'

@description('Container image for the LiteLLM proxy.')
param litellmImage string = 'ghcr.io/berriai/litellm:main-stable'

@description('Master key LiteLLM requires from callers; Foundry presents it as the connection credential.')
@secure()
param litellmMasterKey string

@description('Password for the in-cluster PostgreSQL backend (sidecar). Override for anything beyond a POC.')
@secure()
param dbPassword string = 'pg-${uniqueString(resourceGroup().id, 'litellm-db')}'

@description('Container image for the PostgreSQL backend that gives LiteLLM a control-plane database (enables the A2A agent gateway, virtual keys, spend tracking, Admin UI).')
param postgresImage string = 'postgres:16-alpine'

@description('Name of the Foundry Model Gateway connection.')
param connectionName string = 'litellm-gateway'

@description('Model (deployment) name exposed by LiteLLM and registered in the connection.')
param modelName string = 'gpt-4o-mini'

@description('Underlying model version (metadata only).')
param modelVersion string = '2024-07-18'

// ------------------
//    VARIABLES
// ------------------

var suffix = uniqueString(resourceGroup().id)
var cognitiveServicesUserRoleId = 'a97b65f3-24c7-4388-baec-2e87135dc908' // Cognitive Services User

// Static model list registered on the connection (JSON string — Foundry requires
// complex metadata values to be serialized).
var modelsMetadata = '[{"name":"${modelName}","properties":{"model":{"name":"${modelName}","version":"${modelVersion}","format":"OpenAI"}}}]'
// LiteLLM expects "Authorization: Bearer <master_key>".
var authConfigMetadata = '{"type":"api_key","name":"Authorization","format":"Bearer {api_key}"}'

// PostgreSQL backend (sidecar) connection string. LiteLLM reads DATABASE_URL and runs its
// Prisma migrations automatically on startup. The DB runs in the SAME replica, reachable
// over localhost (containers in a Container App share the network namespace).
var pgUser = 'litellm'
var pgDatabase = 'litellm'
var databaseUrl = 'postgresql://${pgUser}:${dbPassword}@localhost:5432/${pgDatabase}'

// ------------------
//    EXISTING FOUNDRY ACCOUNTS
// ------------------

resource foundry 'Microsoft.CognitiveServices/accounts@2025-06-01' existing = [
  for name in foundryAccountNames: {
    name: name
  }
]

resource connectionAccount 'Microsoft.CognitiveServices/accounts@2025-06-01' existing = {
  name: connectionAccountName
}

// ------------------
//    MANAGED IDENTITY + ROLE ASSIGNMENTS
// ------------------

resource uami 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-litellm-${suffix}'
  location: location
}

resource roleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for (name, i) in foundryAccountNames: {
    scope: foundry[i]
    name: guid(foundry[i].id, uami.id, cognitiveServicesUserRoleId)
    properties: {
      roleDefinitionId: resourceId('Microsoft.Authorization/roleDefinitions', cognitiveServicesUserRoleId)
      principalId: uami.properties.principalId
      principalType: 'ServicePrincipal'
    }
  }
]

// ------------------
//    CONTAINER APPS ENVIRONMENT
// ------------------

resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: 'log-litellm-${suffix}'
  location: location
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
  }
}

resource managedEnv 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: 'cae-litellm-${suffix}'
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
//    LITELLM CONTAINER APP
// ------------------

resource litellmApp 'Microsoft.App/containerApps@2024-03-01' = {
  name: 'ca-litellm-${suffix}'
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${uami.id}': {}
    }
  }
  properties: {
    managedEnvironmentId: managedEnv.id
    configuration: {
      ingress: {
        external: true
        targetPort: 4000
        transport: 'auto'
      }
      secrets: [
        {
          name: 'litellm-master-key'
          value: litellmMasterKey
        }
        {
          name: 'litellm-config'
          value: loadTextContent('../src/litellm/config.foundry.yaml')
        }
        {
          name: 'db-password'
          value: dbPassword
        }
        {
          name: 'database-url'
          value: databaseUrl
        }
      ]
    }
    template: {
      containers: [
        {
          name: 'litellm'
          image: litellmImage
          command: [
            'litellm'
          ]
          args: [
            '--config'
            '/etc/litellm/config.yaml'
            '--port'
            '4000'
          ]
          resources: {
            cpu: json('1.0')
            memory: '2Gi'
          }
          env: [
            {
              name: 'FOUNDRY1_API_BASE'
              value: 'https://${foundry[0].properties.customSubDomainName}.openai.azure.com/'
            }
            {
              name: 'FOUNDRY2_API_BASE'
              value: 'https://${foundry[1].properties.customSubDomainName}.openai.azure.com/'
            }
            {
              name: 'AZURE_API_VERSION'
              value: apiVersion
            }
            {
              // Tells DefaultAzureCredential to use this user-assigned identity.
              name: 'AZURE_CLIENT_ID'
              value: uami.properties.clientId
            }
            {
              name: 'LITELLM_MASTER_KEY'
              secretRef: 'litellm-master-key'
            }
            {
              // Points LiteLLM at the PostgreSQL sidecar. Setting this turns on the
              // DB-backed control plane: the A2A Agent Gateway, virtual keys, spend
              // tracking and the Admin UI. LiteLLM runs its migrations on startup.
              name: 'DATABASE_URL'
              secretRef: 'database-url'
            }
            {
              // Persist agents/keys created at runtime (vs. only config.yaml entries).
              name: 'STORE_MODEL_IN_DB'
              value: 'True'
            }
          ]
          volumeMounts: [
            {
              volumeName: 'config'
              mountPath: '/etc/litellm'
            }
          ]
        }
        {
          // PostgreSQL backend for LiteLLM, co-located in the same replica. The data
          // directory uses ephemeral (EmptyDir) storage, so registrations are re-created
          // by the deploy step — fine for a POC/lab. For production use Azure Database for
          // PostgreSQL Flexible Server and set DATABASE_URL to it instead.
          name: 'postgres'
          image: postgresImage
          resources: {
            cpu: json('0.5')
            memory: '1Gi'
          }
          env: [
            {
              name: 'POSTGRES_USER'
              value: pgUser
            }
            {
              name: 'POSTGRES_PASSWORD'
              secretRef: 'db-password'
            }
            {
              name: 'POSTGRES_DB'
              value: pgDatabase
            }
            {
              // Keep PGDATA in a subdirectory of the mounted volume (required when the
              // mount root may contain a lost+found / is not empty).
              name: 'PGDATA'
              value: '/var/lib/postgresql/data/pgdata'
            }
          ]
          volumeMounts: [
            {
              volumeName: 'pgdata'
              mountPath: '/var/lib/postgresql/data'
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
          name: 'config'
          storageType: 'Secret'
          secrets: [
            {
              secretRef: 'litellm-config'
              path: 'config.yaml'
            }
          ]
        }
        {
          // Ephemeral scratch disk shared within the replica for the Postgres data dir.
          name: 'pgdata'
          storageType: 'EmptyDir'
        }
      ]
    }
  }
}

// ------------------
//    FOUNDRY MODEL GATEWAY CONNECTION
// ------------------

resource modelGatewayConnection 'Microsoft.CognitiveServices/accounts/connections@2025-04-01-preview' = {
  parent: connectionAccount
  name: connectionName
  properties: {
    category: 'ModelGateway'
    target: 'https://${litellmApp.properties.configuration.ingress.fqdn}'
    authType: 'ApiKey'
    credentials: {
      key: litellmMasterKey
    }
    metadata: {
      // Static model discovery — no /models call needed.
      models: modelsMetadata
      // false => POST {target}/chat/completions with {"model": "<deploymentName>"}.
      deploymentInPath: 'false'
      authConfig: authConfigMetadata
    }
  }
}

// ------------------
//    OUTPUTS
// ------------------

output gatewayFqdn string = litellmApp.properties.configuration.ingress.fqdn
output gatewayUrl string = 'https://${litellmApp.properties.configuration.ingress.fqdn}'
output connectionName string = connectionName
output connectionAccount string = connectionAccountName
@description('Use this as FOUNDRY_MODEL_DEPLOYMENT_NAME for the agent: <connection>/<model>.')
output modelDeploymentName string = '${connectionName}/${modelName}'
