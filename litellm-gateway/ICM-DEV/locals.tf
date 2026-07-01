###############################################################################
#  Shared data + locals for the LiteLLM additions.
###############################################################################

data "azurerm_client_config" "current" {
  provider = azurerm.miroki-dev
}

locals {
  # The two regional Foundry endpoints LiteLLM load balances across.
  foundry_api_bases = [
    for f in azurerm_cognitive_account.foundry : "https://${f.custom_subdomain_name}.openai.azure.com/"
  ]

  # PostgreSQL connection string for LiteLLM (keys/spend/budgets live here).
  # Password comes from the variable (the data source cannot expose it).
  database_url = "postgresql://${var.pg_admin_login}:${var.pg_admin_password}@${data.azurerm_postgresql_flexible_server.existing.fqdn}:5432/${var.pg_database}?sslmode=require"

  # LiteLLM model/router config, delivered to the container as a mounted secret.
  litellm_config = templatefile("${path.module}/litellm.config.yaml.tftpl", {
    public_model_name = var.public_model_name
    deployment_name   = var.model_deployment_name
    store_model_in_db = var.store_model_in_db
  })
}
