###############################################################################
#  LiteLLM AI gateway on Azure Container Apps
#  ACA + ACA env + PostgreSQL Flexible Server + Key Vault + 2 Foundry backends
#
#  LiteLLM exposes one OpenAI-compatible endpoint and load balances across two
#  Azure AI Foundry GPT-4 deployments in two regions. It authenticates to the
#  Foundries with a user-assigned managed identity (keyless). The LiteLLM master
#  key and the PostgreSQL connection string live in Key Vault and are surfaced to
#  the container as Key Vault-referenced secrets via the same identity.
###############################################################################

data "azurerm_client_config" "current" {}

resource "random_string" "suffix" {
  length  = 6
  lower   = true
  upper   = false
  numeric = true
  special = false
}

# Master key callers present to LiteLLM (and Foundry's connection, if added later).
resource "random_password" "master_key" {
  length  = 40
  special = false
}

# PostgreSQL admin password (kept out of state output; stored in Key Vault).
resource "random_password" "pg" {
  length      = 32
  special     = false
  min_upper   = 1
  min_lower   = 1
  min_numeric = 1
}

locals {
  suffix      = random_string.suffix.result
  rg_name     = var.create_resource_group ? azurerm_resource_group.this[0].name : var.resource_group_name
  rg_location = var.location

  master_key = "sk-${random_password.master_key.result}"

  # API bases LiteLLM uses for the two regional backends.
  foundry_api_bases = var.create_foundries ? [
    for f in azurerm_cognitive_account.foundry : "https://${f.custom_subdomain_name}.openai.azure.com/"
  ] : var.existing_foundry_api_bases

  database_url = "postgresql://${var.pg_admin_login}:${random_password.pg.result}@${azurerm_postgresql_flexible_server.pg.fqdn}:5432/litellm?sslmode=require"

  litellm_config = templatefile("${path.module}/litellm.config.yaml.tftpl", {
    public_model_name = var.public_model_name
    deployment_name   = var.model_deployment_name
  })
}

###############################################################################
#  Resource group
###############################################################################

resource "azurerm_resource_group" "this" {
  count    = var.create_resource_group ? 1 : 0
  name     = var.resource_group_name
  location = var.location
  tags     = var.tags
}

###############################################################################
#  User-assigned managed identity for the LiteLLM container
#  Skipped when var.vanilla = true (then the APP module / bootstrap creates the
#  identity + RBAC instead). See variables.tf and the app module's bootstrap.
###############################################################################

resource "azurerm_user_assigned_identity" "litellm" {
  count               = var.vanilla ? 0 : 1
  name                = "id-${var.name_prefix}-${local.suffix}"
  resource_group_name = local.rg_name
  location            = local.rg_location
  tags                = var.tags
}

###############################################################################
#  Foundry accounts + GPT-4 deployments (optional)
###############################################################################

resource "azurerm_cognitive_account" "foundry" {
  count = var.create_foundries ? length(var.foundry_regions) : 0

  name                  = "${var.name_prefix}-fdry${count.index + 1}-${local.suffix}"
  resource_group_name   = local.rg_name
  location              = var.foundry_regions[count.index]
  kind                  = "AIServices"
  sku_name              = "S0"
  custom_subdomain_name = "${var.name_prefix}-fdry${count.index + 1}-${local.suffix}"

  # When private networking is on, the account is reachable only through its
  # private endpoint; LiteLLM resolves it via the linked private DNS zones.
  public_network_access_enabled = !var.enable_private_networking

  tags = var.tags
}

resource "azurerm_cognitive_deployment" "gpt4" {
  count = var.create_foundries ? length(var.foundry_regions) : 0

  name                 = var.model_deployment_name
  cognitive_account_id = azurerm_cognitive_account.foundry[count.index].id

  model {
    format  = "OpenAI"
    name    = var.model_name
    version = var.model_version
  }

  sku {
    name     = var.model_sku_name
    capacity = var.model_capacity
  }
}

# LiteLLM identity -> Cognitive Services User on each created Foundry (keyless).
resource "azurerm_role_assignment" "uami_foundry_user" {
  count = (var.create_foundries && !var.vanilla) ? length(var.foundry_regions) : 0

  scope                = azurerm_cognitive_account.foundry[count.index].id
  role_definition_name = "Cognitive Services User"
  principal_id         = azurerm_user_assigned_identity.litellm[0].principal_id
}

###############################################################################
#  PostgreSQL Flexible Server (LiteLLM control-plane DB)
###############################################################################

resource "azurerm_postgresql_flexible_server" "pg" {
  name                          = "pg-${var.name_prefix}-${local.suffix}-${replace(var.pg_location != null ? var.pg_location : local.rg_location, "/[^a-z0-9]/", "")}"
  resource_group_name           = local.rg_name
  location                      = var.pg_location != null ? var.pg_location : local.rg_location
  version                       = var.pg_version
  administrator_login           = var.pg_admin_login
  administrator_password        = random_password.pg.result
  sku_name                      = var.pg_sku_name
  storage_mb                    = var.pg_storage_mb
  public_network_access_enabled = true
  tags                          = var.tags

  authentication {
    password_auth_enabled = true
  }

  lifecycle {
    # Some regions reject an explicit zone; let Azure place the server.
    ignore_changes = [zone]
  }
}

resource "azurerm_postgresql_flexible_server_database" "litellm" {
  name      = "litellm"
  server_id = azurerm_postgresql_flexible_server.pg.id
  charset   = "UTF8"
  collation = "en_US.utf8"
}

# Allow Azure services (incl. the Container App egress) to reach the server.
# 0.0.0.0/0.0.0.0 is the Azure-internal "allow all Azure services" rule.
resource "azurerm_postgresql_flexible_server_firewall_rule" "allow_azure" {
  name             = "AllowAzureServices"
  server_id        = azurerm_postgresql_flexible_server.pg.id
  start_ip_address = "0.0.0.0"
  end_ip_address   = "0.0.0.0"
}

###############################################################################
#  Key Vault + secrets (master key, database url)
###############################################################################

resource "azurerm_key_vault" "kv" {
  name                       = "kv-${var.name_prefix}-${local.suffix}"
  resource_group_name        = local.rg_name
  location                   = local.rg_location
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  rbac_authorization_enabled = true
  purge_protection_enabled   = false
  tags                       = var.tags
}

# Deployer can write secrets.
resource "azurerm_role_assignment" "deployer_kv_officer" {
  count                = var.vanilla ? 0 : 1
  scope                = azurerm_key_vault.kv.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = data.azurerm_client_config.current.object_id
}

# LiteLLM identity can read secrets (used by the ACA Key Vault secret references).
resource "azurerm_role_assignment" "uami_kv_secrets_user" {
  count                = var.vanilla ? 0 : 1
  scope                = azurerm_key_vault.kv.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.litellm[0].principal_id
}

# RBAC is eventually consistent; wait before writing secrets.
resource "time_sleep" "kv_rbac" {
  count           = var.vanilla ? 0 : 1
  depends_on      = [azurerm_role_assignment.deployer_kv_officer]
  create_duration = "30s"
}

resource "azurerm_key_vault_secret" "master_key" {
  count        = var.vanilla ? 0 : 1
  name         = "litellm-master-key"
  value        = local.master_key
  key_vault_id = azurerm_key_vault.kv.id
  depends_on   = [time_sleep.kv_rbac]
}

resource "azurerm_key_vault_secret" "database_url" {
  count        = var.vanilla ? 0 : 1
  name         = "database-url"
  value        = local.database_url
  key_vault_id = azurerm_key_vault.kv.id
  depends_on   = [time_sleep.kv_rbac]
}

###############################################################################
#  Log Analytics + Container Apps environment
###############################################################################

resource "azurerm_log_analytics_workspace" "logs" {
  name                = "log-${var.name_prefix}-${local.suffix}"
  resource_group_name = local.rg_name
  location            = local.rg_location
  sku                 = "PerGB2018"
  retention_in_days   = 30
  tags                = var.tags
}

resource "azurerm_container_app_environment" "cae" {
  name                       = "cae-${var.name_prefix}-${local.suffix}"
  resource_group_name        = local.rg_name
  location                   = local.rg_location
  log_analytics_workspace_id = azurerm_log_analytics_workspace.logs.id

  # VNet-integrate the environment when private networking is on. Ingress stays
  # external (public) so the gateway is testable; egress flows through the VNet,
  # so LiteLLM reaches the Foundry private endpoints over the private network.
  infrastructure_subnet_id       = var.enable_private_networking ? azurerm_subnet.aca[0].id : null
  internal_load_balancer_enabled = var.enable_private_networking ? false : null

  tags = var.tags
}

###############################################################################
#  LiteLLM Container App
###############################################################################

resource "azurerm_container_app" "litellm" {
  count                        = (var.deploy_litellm_app && !var.vanilla) ? 1 : 0
  name                         = "ca-${var.name_prefix}-${local.suffix}"
  resource_group_name          = local.rg_name
  container_app_environment_id = azurerm_container_app_environment.cae.id
  revision_mode                = "Single"
  tags                         = var.tags

  identity {
    type         = "UserAssigned"
    identity_ids = [one(azurerm_user_assigned_identity.litellm[*].id)]
  }

  # Key Vault-referenced secrets, read with the LiteLLM identity.
  secret {
    name                = "litellm-master-key"
    identity            = one(azurerm_user_assigned_identity.litellm[*].id)
    key_vault_secret_id = one(azurerm_key_vault_secret.master_key[*].versionless_id)
  }

  secret {
    name                = "database-url"
    identity            = one(azurerm_user_assigned_identity.litellm[*].id)
    key_vault_secret_id = one(azurerm_key_vault_secret.database_url[*].versionless_id)
  }

  # The LiteLLM config is delivered as a mounted file (matches the proven Bicep
  # approach) rather than an env var, so the YAML reaches the proxy byte-for-byte.
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
      image  = var.litellm_image
      cpu    = var.litellm_cpu
      memory = var.litellm_memory

      # Start LiteLLM against the mounted config file (the Secret volume mounts each
      # app secret as a file named after the secret -> /etc/litellm/litellm-config).
      command = [
        "litellm",
        "--config",
        "/etc/litellm/litellm-config",
        "--port",
        "4000",
      ]

      env {
        name  = "FOUNDRY1_API_BASE"
        value = local.foundry_api_bases[0]
      }
      env {
        name  = "FOUNDRY2_API_BASE"
        value = local.foundry_api_bases[1]
      }
      env {
        name  = "AZURE_API_VERSION"
        value = var.api_version
      }
      env {
        name  = "AZURE_CLIENT_ID"
        value = one(azurerm_user_assigned_identity.litellm[*].client_id)
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

  depends_on = [
    azurerm_role_assignment.uami_kv_secrets_user,
    azurerm_postgresql_flexible_server_database.litellm,
    azurerm_postgresql_flexible_server_firewall_rule.allow_azure,
  ]
}

###############################################################################
#  Private networking (optional) — VNet + ACA integration + Foundry PEs
#  Set enable_private_networking = true to deploy. Simulates a locked-down env:
#  the Foundries have public access disabled and are reachable only over private
#  endpoints in the same VNet the Container Apps environment is integrated into.
###############################################################################

locals {
  pdns_zones = var.enable_private_networking ? [
    "privatelink.openai.azure.com",
    "privatelink.cognitiveservices.azure.com",
    "privatelink.services.ai.azure.com",
  ] : []
}

resource "azurerm_virtual_network" "vnet" {
  count               = var.enable_private_networking ? 1 : 0
  name                = "vnet-${var.name_prefix}-${local.suffix}"
  resource_group_name = local.rg_name
  location            = local.rg_location
  address_space       = var.vnet_address_space
  tags                = var.tags
}

resource "azurerm_subnet" "aca" {
  count                = var.enable_private_networking ? 1 : 0
  name                 = "snet-aca"
  resource_group_name  = local.rg_name
  virtual_network_name = azurerm_virtual_network.vnet[0].name
  address_prefixes     = [var.aca_subnet_prefix]

  delegation {
    name = "aca-env"
    service_delegation {
      name    = "Microsoft.App/environments"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

resource "azurerm_subnet" "pe" {
  count                             = var.enable_private_networking ? 1 : 0
  name                              = "snet-pe"
  resource_group_name               = local.rg_name
  virtual_network_name              = azurerm_virtual_network.vnet[0].name
  address_prefixes                  = [var.pe_subnet_prefix]
  private_endpoint_network_policies = "Disabled"
}

resource "azurerm_private_dns_zone" "z" {
  for_each            = toset(local.pdns_zones)
  name                = each.value
  resource_group_name = local.rg_name
  tags                = var.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "z" {
  for_each              = azurerm_private_dns_zone.z
  name                  = "link-${replace(each.key, ".", "-")}"
  resource_group_name   = local.rg_name
  private_dns_zone_name = each.value.name
  virtual_network_id    = azurerm_virtual_network.vnet[0].id
  registration_enabled  = false
  tags                  = var.tags
}

resource "azurerm_private_endpoint" "foundry" {
  count               = var.enable_private_networking && var.create_foundries ? length(var.foundry_regions) : 0
  name                = "pe-${var.name_prefix}-fdry${count.index + 1}-${local.suffix}"
  resource_group_name = local.rg_name
  location            = local.rg_location
  subnet_id           = azurerm_subnet.pe[0].id
  tags                = var.tags

  private_service_connection {
    name                           = "psc-fdry${count.index + 1}"
    private_connection_resource_id = azurerm_cognitive_account.foundry[count.index].id
    subresource_names              = ["account"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = [for z in azurerm_private_dns_zone.z : z.id]
  }
}
