data "azurerm_client_config" "current" {}

resource "random_string" "suffix" {
  length  = 4
  lower   = true
  upper   = false
  numeric = true
  special = false
}

resource "random_password" "master_key" {
  length  = 40
  special = false
}

resource "random_password" "salt_key" {
  length  = 32
  special = false
}

resource "random_password" "pg" {
  length      = 32
  special     = false
  min_upper   = 1
  min_lower   = 1
  min_numeric = 1
}

locals {
  suffix = "${var.name_suffix}${random_string.suffix.result}"

  # The two Foundry endpoints LiteLLM load balances across.
  foundry_api_bases = [for f in azurerm_cognitive_account.foundry : "https://${f.custom_subdomain_name}.openai.azure.com/"]

  # PostgreSQL is always private; the VNet-integrated ACA env reaches it by FQDN.
  database_url = "postgresql://${var.pg_admin_login}:${random_password.pg.result}@${azurerm_postgresql_flexible_server.pg.fqdn}:5432/${var.pg_database}?sslmode=require"

  litellm_config = templatefile("${path.module}/litellm.config.yaml.tftpl", {
    public_model_name = var.public_model_name
    deployment_name   = var.model_deployment_name
    store_model_in_db = var.store_model_in_db
  })
}
