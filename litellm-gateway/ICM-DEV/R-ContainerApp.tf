###############################################################################
#  ADDED: the NEW PUBLIC test LiteLLM app (throwaway). Runs on the public test
#  env, uses the EXISTING managed identity (keyless to the Foundries + KV), and
#  reads the master key from Key Vault. DATABASE_URL is wired only when
#  test_app_use_database = true (requires the VNet-integrated test env).
###############################################################################

resource "azurerm_container_app" "test" {
  provider                     = azurerm.miroki-dev
  name                         = var.test_app_name
  container_app_environment_id = azurerm_container_app_environment.test.id
  resource_group_name          = var.resource_group_name
  revision_mode                = "Single"
  tags                         = var.tags

  identity {
    type         = "UserAssigned"
    identity_ids = [data.azurerm_user_assigned_identity.existing.id]
  }

  # Always present: master key (from Key Vault) + the mounted config.
  secret {
    name                = "litellm-master-key"
    identity            = data.azurerm_user_assigned_identity.existing.id
    key_vault_secret_id = azurerm_key_vault_secret.master_key.versionless_id
  }
  secret {
    name  = "litellm-config"
    value = local.litellm_config
  }

  # Only when using the DB: salt key + connection string (from Key Vault).
  dynamic "secret" {
    for_each = var.test_app_use_database ? {
      "litellm-salt-key" = one(azurerm_key_vault_secret.salt_key[*].versionless_id)
      "database-url"     = one(azurerm_key_vault_secret.database_url[*].versionless_id)
    } : {}
    content {
      name                = secret.key
      identity            = data.azurerm_user_assigned_identity.existing.id
      key_vault_secret_id = secret.value
    }
  }

  ingress {
    allow_insecure_connections = false
    external_enabled           = true
    target_port                = var.litellm_target_port
    transport                  = "auto"
    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }

  template {
    min_replicas    = 1
    max_replicas    = 2
    revision_suffix = ""

    container {
      name   = "litellm"
      image  = var.litellm_image
      cpu    = 1.0
      memory = "2Gi"

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
      # Keyless auth: DefaultAzureCredential uses this identity's client id.
      env {
        name  = "AZURE_CLIENT_ID"
        value = data.azurerm_user_assigned_identity.existing.client_id
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

      # DB-backed persistence (virtual keys/budgets) only when enabled.
      dynamic "env" {
        for_each = var.test_app_use_database ? {
          "LITELLM_SALT_KEY" = "litellm-salt-key"
          "DATABASE_URL"     = "database-url"
        } : {}
        content {
          name        = env.key
          secret_name = env.value
        }
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
    azurerm_container_app_environment.test,
    azurerm_role_assignment.identity_kv_secrets_user,
    azurerm_role_assignment.identity_foundry_user,
    azurerm_key_vault_secret.master_key,
  ]
}

