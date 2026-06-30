###############################################################################
#  Read the existing infra outputs (deployed separately, e.g. by a partner).
###############################################################################

data "terraform_remote_state" "infra" {
  count   = var.infra_state_path != "" ? 1 : 0
  backend = "local"
  config = {
    path = var.infra_state_path
  }
}

locals {
  use_state = var.infra_state_path != ""
  o         = local.use_state ? data.terraform_remote_state.infra[0].outputs : null

  rg                = local.use_state ? local.o.resource_group_name : var.resource_group_name
  location          = local.use_state ? local.o.location : var.location
  app_name          = local.use_state ? local.o.container_app_name : var.container_app_name
  cae_id            = local.use_state ? local.o.container_app_environment_id : var.container_app_environment_id
  identity_id       = local.use_state ? local.o.identity_id : var.identity_id
  identity_clientid = local.use_state ? local.o.identity_client_id : var.identity_client_id
  mk_secret_uri     = local.use_state ? local.o.master_key_secret_uri : var.master_key_secret_uri
  db_secret_uri     = local.use_state ? local.o.database_url_secret_uri : var.database_url_secret_uri
  foundry_bases     = local.use_state ? local.o.foundry_api_bases : var.foundry_api_bases
  api_version       = local.use_state ? local.o.api_version : var.api_version
  deployment_name   = local.use_state ? local.o.model_deployment_name : var.model_deployment_name
  public_model_name = local.use_state ? local.o.public_model_name : var.public_model_name
  master_key        = local.use_state ? local.o.litellm_master_key : var.litellm_master_key
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
}
