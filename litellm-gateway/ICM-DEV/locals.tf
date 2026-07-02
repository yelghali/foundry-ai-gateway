data "azurerm_client_config" "current" {}

# Auto-detect the deployer's public egress IP (only when key_vault_allowed_ip is
# not set) so this run can write secrets to the otherwise-private Key Vault.
data "http" "deployer_ip" {
  count = var.key_vault_allowed_ip == "" ? 1 : 0
  url   = "https://api.ipify.org"
}

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

  # Deployer IP allowed to write Key Vault secrets (the app reads over the PE).
  kv_deployer_ip = var.key_vault_allowed_ip != "" ? var.key_vault_allowed_ip : (length(data.http.deployer_ip) > 0 ? chomp(data.http.deployer_ip[0].response_body) : "")
  kv_ip_rules    = local.kv_deployer_ip != "" ? [local.kv_deployer_ip] : []

  # Private DNS zone IDs for the Foundry / Key Vault endpoints: use the ones we
  # create (create_private_dns_zones = true) or the shared pre-existing IDs.
  openai_zone_id            = var.create_private_dns_zones ? one(azurerm_private_dns_zone.openai[*].id) : var.private_dns_zone_id_openai
  cognitiveservices_zone_id = var.create_private_dns_zones ? one(azurerm_private_dns_zone.cognitiveservices[*].id) : var.private_dns_zone_id_cognitiveservices
  services_ai_zone_id       = var.create_private_dns_zones ? one(azurerm_private_dns_zone.services_ai[*].id) : var.private_dns_zone_id_services_ai
  vault_zone_id             = var.create_private_dns_zones ? one(azurerm_private_dns_zone.vault[*].id) : var.private_dns_zone_id_vault

  # An Azure AI Foundry (AIServices) account private endpoint (subresource
  # "account") resolves over three FQDNs and needs all three zones.
  foundry_zone_ids = [local.openai_zone_id, local.cognitiveservices_zone_id, local.services_ai_zone_id]

  # The two Foundry endpoints LiteLLM load balances across.
  foundry_api_bases = [for f in azurerm_cognitive_account.foundry : "https://${f.custom_subdomain_name}.openai.azure.com/"]

  # Private Redis Container App hostname (internal ACA load balancer) — only set
  # when enable_redis = true; consumed by the LiteLLM router for shared state.
  redis_host = var.enable_redis ? azurerm_container_app.redis[0].ingress[0].fqdn : ""

  # PostgreSQL is always private; the VNet-integrated ACA env reaches it by FQDN.
  database_url = "postgresql://${var.pg_admin_login}:${random_password.pg.result}@${azurerm_postgresql_flexible_server.pg.fqdn}:5432/${var.pg_database}?sslmode=require"

  litellm_config = templatefile("${path.module}/litellm.config.yaml.tftpl", {
    public_model_name = var.public_model_name
    deployment_name   = var.model_deployment_name
    store_model_in_db = var.store_model_in_db
    redis_enabled     = var.enable_redis
  })
}
