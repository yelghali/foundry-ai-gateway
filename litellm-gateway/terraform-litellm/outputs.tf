###############################################################################
#  LiteLLM app outputs (only when Terraform manages the container app)
###############################################################################

output "litellm_url" {
  description = "Public HTTPS endpoint of the LiteLLM gateway (null when deploy_litellm_app = false)."
  value       = var.deploy_litellm_app ? "https://${azurerm_container_app.litellm[0].ingress[0].fqdn}" : null
}

output "litellm_fqdn" {
  description = "FQDN of the LiteLLM Container App (null when deploy_litellm_app = false)."
  value       = var.deploy_litellm_app ? azurerm_container_app.litellm[0].ingress[0].fqdn : null
}

output "litellm_master_key" {
  description = "Master key callers present to LiteLLM (also stored in Key Vault)."
  value       = local.master_key
  sensitive   = true
}

output "public_model_name" {
  description = "Model name callers pass to LiteLLM."
  value       = var.public_model_name
}

###############################################################################
#  Infra outputs (consumed by the terraform-litellm-app module when infra-only)
###############################################################################

output "resource_group_name" {
  description = "Resource group the stack was deployed into."
  value       = local.rg_name
}

output "location" {
  description = "Primary location."
  value       = local.rg_location
}

output "container_app_name" {
  description = "Name the LiteLLM Container App should use."
  value       = "ca-${var.name_prefix}-${local.suffix}"
}

output "container_app_environment_id" {
  description = "Resource id of the Container Apps environment."
  value       = azurerm_container_app_environment.cae.id
}

output "identity_id" {
  description = "Resource id of the user-assigned managed identity for LiteLLM."
  value       = azurerm_user_assigned_identity.litellm.id
}

output "identity_client_id" {
  description = "Client id of the LiteLLM managed identity (AZURE_CLIENT_ID)."
  value       = azurerm_user_assigned_identity.litellm.client_id
}

output "key_vault_name" {
  description = "Key Vault holding the master key and database URL."
  value       = azurerm_key_vault.kv.name
}

output "master_key_secret_uri" {
  description = "Versionless Key Vault secret URI for the LiteLLM master key (for ACA keyvaultref)."
  value       = azurerm_key_vault_secret.master_key.versionless_id
}

output "database_url_secret_uri" {
  description = "Versionless Key Vault secret URI for the PostgreSQL connection string (for ACA keyvaultref)."
  value       = azurerm_key_vault_secret.database_url.versionless_id
}

output "foundry_api_bases" {
  description = "The two regional Foundry endpoints LiteLLM load balances across."
  value       = local.foundry_api_bases
}

output "api_version" {
  description = "Azure OpenAI API version LiteLLM uses."
  value       = var.api_version
}

output "model_deployment_name" {
  description = "Azure deployment name of the model (azure/<this>)."
  value       = var.model_deployment_name
}

output "litellm_image" {
  description = "LiteLLM container image."
  value       = var.litellm_image
}

output "postgres_fqdn" {
  description = "PostgreSQL Flexible Server FQDN."
  value       = azurerm_postgresql_flexible_server.pg.fqdn
}
