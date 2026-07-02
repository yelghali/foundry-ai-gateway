###############################################################################
#  Container Apps environment — ALWAYS VNet-integrated (snet-appintegration) so
#  it can reach the private-endpoint Foundries / Key Vault / PostgreSQL.
#  private_ingress = false -> PUBLIC (external) ingress for testing.
#  private_ingress = true  -> INTERNAL (VNet-private) ingress.
###############################################################################

resource "azurerm_container_app_environment" "cae" {
  name                           = "cae-${var.name_prefix}-${local.suffix}"
  resource_group_name            = var.resource_group_name
  location                       = var.location
  log_analytics_workspace_id     = azurerm_log_analytics_workspace.logs.id
  infrastructure_subnet_id       = var.aca_infrastructure_subnet_id
  internal_load_balancer_enabled = var.private_ingress
  tags                           = var.tags

  workload_profile {
    name                  = "Consumption"
    workload_profile_type = "Consumption"
    maximum_count         = 0
    minimum_count         = 0
  }
}

###############################################################################
#  LiteLLM Container App.
###############################################################################

resource "azurerm_container_app" "litellm" {
  name                         = "ca-${var.name_prefix}-${local.suffix}"
  resource_group_name          = var.resource_group_name
  container_app_environment_id = azurerm_container_app_environment.cae.id
  revision_mode                = "Single"
  workload_profile_name        = "Consumption"
  tags                         = var.tags

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.litellm.id]
  }

  secret {
    name                = "litellm-master-key"
    identity            = azurerm_user_assigned_identity.litellm.id
    key_vault_secret_id = azurerm_key_vault_secret.master_key.versionless_id
  }
  secret {
    name                = "litellm-salt-key"
    identity            = azurerm_user_assigned_identity.litellm.id
    key_vault_secret_id = azurerm_key_vault_secret.salt_key.versionless_id
  }
  secret {
    name                = "database-url"
    identity            = azurerm_user_assigned_identity.litellm.id
    key_vault_secret_id = azurerm_key_vault_secret.database_url.versionless_id
  }
  secret {
    name  = "litellm-config"
    value = local.litellm_config
  }

  ingress {
    external_enabled = true
    target_port      = var.litellm_target_port
    transport        = "auto"
    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }

  template {
    min_replicas = 1
    max_replicas = 2

    container {
      name   = "litellm"
      image  = var.litellm_image
      cpu    = var.litellm_cpu
      memory = var.litellm_memory

      command = [
        "litellm",
        "--config",
        "/etc/litellm/litellm-config",
        "--port",
        tostring(var.litellm_target_port),
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
        value = azurerm_user_assigned_identity.litellm.client_id
      }
      env {
        name  = "STORE_MODEL_IN_DB"
        value = var.store_model_in_db ? "True" : "False"
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
        name        = "LITELLM_SALT_KEY"
        secret_name = "litellm-salt-key"
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
    azurerm_role_assignment.identity_kv_secrets_user,
    azurerm_role_assignment.identity_foundry_user,
    azurerm_key_vault_secret.master_key,
    azurerm_key_vault_secret.salt_key,
    azurerm_key_vault_secret.database_url,
    azurerm_postgresql_flexible_server_database.litellm,
    # Ensure the Foundry private endpoints (and their DNS records) exist before
    # the container starts, so LiteLLM's startup health check can reach the
    # private Foundry accounts and does not cool the deployments down.
    azurerm_private_endpoint.foundry,
  ]
}
