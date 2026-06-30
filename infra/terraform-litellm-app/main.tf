###############################################################################
#  Read the existing infra outputs (deployed separately, e.g. by a partner).
#  Three sources, selected by var.infra_state_backend:
#    - "local"   : a state file on disk          (var.infra_state_path)
#    - "azurerm" : remote state in an Azure blob  (var.infra_state_config)
#    - "none"    : no state — use explicit vars / TF_VAR_* (env-var fallback)
#  Bootstrap mode ignores state entirely.
###############################################################################

locals {
  read_local  = !var.bootstrap && var.infra_state_backend == "local" && var.infra_state_path != ""
  read_remote = !var.bootstrap && var.infra_state_backend == "azurerm"
}

data "terraform_remote_state" "infra_local" {
  count   = local.read_local ? 1 : 0
  backend = "local"
  config = {
    path = var.infra_state_path
  }
}

data "terraform_remote_state" "infra_remote" {
  count   = local.read_remote ? 1 : 0
  backend = "azurerm"
  config  = var.infra_state_config
}

###############################################################################
#  BOOTSTRAP resources — only created when var.bootstrap = true (minimal infra:
#  ACA env + PostgreSQL + Key Vault exist; identity/RBAC/secrets do not).
###############################################################################

data "azurerm_client_config" "current" {
  count = var.bootstrap ? 1 : 0
}

data "azurerm_key_vault" "existing" {
  count               = var.bootstrap ? 1 : 0
  name                = var.key_vault_name
  resource_group_name = var.resource_group_name
}

resource "azurerm_user_assigned_identity" "this" {
  count               = var.bootstrap ? 1 : 0
  name                = "id-${var.name_prefix}-litellm"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags
}

# Identity -> Cognitive Services User on each existing Foundry account (keyless inference).
resource "azurerm_role_assignment" "foundry" {
  count                = var.bootstrap ? length(var.foundry_account_ids) : 0
  scope                = var.foundry_account_ids[count.index]
  role_definition_name = "Cognitive Services User"
  principal_id         = azurerm_user_assigned_identity.this[0].principal_id
}

# Identity -> Key Vault Secrets User (so the container can read the KV-referenced secrets).
resource "azurerm_role_assignment" "kv_user" {
  count                = var.bootstrap ? 1 : 0
  scope                = data.azurerm_key_vault.existing[0].id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.this[0].principal_id
}

# Deployer -> Key Vault Secrets Officer (so this apply can write the two secrets).
resource "azurerm_role_assignment" "deployer_kv_officer" {
  count                = var.bootstrap ? 1 : 0
  scope                = data.azurerm_key_vault.existing[0].id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = data.azurerm_client_config.current[0].object_id
}

resource "random_password" "master_key" {
  count   = var.bootstrap ? 1 : 0
  length  = 40
  special = false
}

resource "time_sleep" "kv_rbac" {
  count           = var.bootstrap ? 1 : 0
  depends_on      = [azurerm_role_assignment.deployer_kv_officer]
  create_duration = "30s"
}

resource "azurerm_key_vault_secret" "master_key" {
  count        = var.bootstrap ? 1 : 0
  name         = "litellm-master-key"
  value        = "sk-${random_password.master_key[0].result}"
  key_vault_id = data.azurerm_key_vault.existing[0].id
  depends_on   = [time_sleep.kv_rbac]
}

resource "azurerm_key_vault_secret" "database_url" {
  count        = var.bootstrap ? 1 : 0
  name         = "database-url"
  value        = "postgresql://${var.pg_admin_login}:${var.pg_admin_password}@${var.postgres_fqdn}:5432/${var.pg_database}?sslmode=require"
  key_vault_id = data.azurerm_key_vault.existing[0].id
  depends_on   = [time_sleep.kv_rbac]
}

locals {
  use_state = local.read_local || local.read_remote
  o = local.read_remote ? data.terraform_remote_state.infra_remote[0].outputs : (
    local.read_local ? data.terraform_remote_state.infra_local[0].outputs : null
  )

  # Resolution order per value: bootstrap-created -> infra state -> explicit var.
  rg                = var.bootstrap ? var.resource_group_name : (local.use_state ? local.o.resource_group_name : var.resource_group_name)
  location          = var.bootstrap ? var.location : (local.use_state ? local.o.location : var.location)
  app_name          = var.bootstrap ? var.container_app_name : (local.use_state ? local.o.container_app_name : var.container_app_name)
  cae_id            = var.bootstrap ? var.container_app_environment_id : (local.use_state ? local.o.container_app_environment_id : var.container_app_environment_id)
  identity_id       = var.bootstrap ? azurerm_user_assigned_identity.this[0].id : (local.use_state ? local.o.identity_id : var.identity_id)
  identity_clientid = var.bootstrap ? azurerm_user_assigned_identity.this[0].client_id : (local.use_state ? local.o.identity_client_id : var.identity_client_id)
  mk_secret_uri     = var.bootstrap ? azurerm_key_vault_secret.master_key[0].versionless_id : (local.use_state ? local.o.master_key_secret_uri : var.master_key_secret_uri)
  db_secret_uri     = var.bootstrap ? azurerm_key_vault_secret.database_url[0].versionless_id : (local.use_state ? local.o.database_url_secret_uri : var.database_url_secret_uri)
  foundry_bases     = var.bootstrap ? var.foundry_api_bases : (local.use_state ? local.o.foundry_api_bases : var.foundry_api_bases)
  api_version       = var.bootstrap ? var.api_version : (local.use_state ? local.o.api_version : var.api_version)
  deployment_name   = var.bootstrap ? var.model_deployment_name : (local.use_state ? local.o.model_deployment_name : var.model_deployment_name)
  public_model_name = var.bootstrap ? var.public_model_name : (local.use_state ? local.o.public_model_name : var.public_model_name)
  master_key        = var.bootstrap ? azurerm_key_vault_secret.master_key[0].value : (local.use_state ? local.o.litellm_master_key : var.litellm_master_key)
  image             = var.litellm_image != "" ? var.litellm_image : (local.use_state ? local.o.litellm_image : "ghcr.io/berriai/litellm:main-stable")

  litellm_config = templatefile("${path.module}/litellm.config.yaml.tftpl", {
    public_model_name = local.public_model_name
    deployment_name   = local.deployment_name
  })
}

###############################################################################
#  LiteLLM Container App (the ONLY resource this module creates).
#  Auth to the Foundries = the infra's user-assigned managed identity (keyless;
#  it already holds "Cognitive Services User" on both Foundries). Secrets come
#  from Key Vault via that identity. Config is delivered as a mounted file.
###############################################################################

resource "azurerm_container_app" "litellm" {
  name                         = local.app_name
  resource_group_name          = local.rg
  container_app_environment_id = local.cae_id
  revision_mode                = "Single"
  tags                         = var.tags

  identity {
    type         = "UserAssigned"
    identity_ids = [local.identity_id]
  }

  secret {
    name                = "litellm-master-key"
    identity            = local.identity_id
    key_vault_secret_id = local.mk_secret_uri
  }

  secret {
    name                = "database-url"
    identity            = local.identity_id
    key_vault_secret_id = local.db_secret_uri
  }

  secret {
    name  = "litellm-config"
    value = local.litellm_config
  }

  ingress {
    external_enabled = true
    target_port      = 4000
    transport        = "auto"

    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }

  template {
    min_replicas = 1
    max_replicas = 1

    container {
      name   = "litellm"
      image  = local.image
      cpu    = var.litellm_cpu
      memory = var.litellm_memory

      command = [
        "litellm",
        "--config",
        "/etc/litellm/litellm-config",
        "--port",
        "4000",
      ]

      env {
        name  = "FOUNDRY1_API_BASE"
        value = local.foundry_bases[0]
      }
      env {
        name  = "FOUNDRY2_API_BASE"
        value = local.foundry_bases[1]
      }
      env {
        name  = "AZURE_API_VERSION"
        value = local.api_version
      }
      env {
        name  = "AZURE_CLIENT_ID"
        value = local.identity_clientid
      }
      env {
        name  = "STORE_MODEL_IN_DB"
        value = "False"
      }
      env {
        name  = "FORWARDED_ALLOW_IPS"
        value = "*"
      }
      env {
        name        = "LITELLM_MASTER_KEY"
        secret_name = "litellm-master-key"
      }
      env {
        name        = "DATABASE_URL"
        secret_name = "database-url"
      }

      volume_mounts {
        name = "config"
        path = "/etc/litellm"
      }
    }

    volume {
      name         = "config"
      storage_type = "Secret"
    }
  }

  # In bootstrap mode, ensure the identity's Key Vault access + the secrets exist
  # before the app starts (these lists are empty when bootstrap = false).
  depends_on = [
    azurerm_role_assignment.kv_user,
    azurerm_role_assignment.foundry,
    azurerm_key_vault_secret.master_key,
    azurerm_key_vault_secret.database_url,
  ]
}
