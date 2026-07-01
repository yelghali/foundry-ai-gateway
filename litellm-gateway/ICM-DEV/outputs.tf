###############################################################################
#  Outputs for the LiteLLM additions (public test env).
###############################################################################

output "litellm_fqdn" {
  description = "Public FQDN of the LiteLLM test gateway."
  value       = azurerm_container_app.test.ingress[0].fqdn
}

output "litellm_url" {
  description = "Public HTTPS endpoint of the LiteLLM test gateway."
  value       = "https://${azurerm_container_app.test.ingress[0].fqdn}"
}

output "litellm_master_key" {
  description = "Master key callers present to LiteLLM (also stored in Key Vault)."
  value       = azurerm_key_vault_secret.master_key.value
  sensitive   = true
}

output "public_model_name" {
  description = "Model name callers pass to LiteLLM."
  value       = var.public_model_name
}

output "foundry_api_bases" {
  description = "The two Foundry endpoints LiteLLM load balances across."
  value       = local.foundry_api_bases
}

output "foundry_account_ids" {
  description = "Resource ids of the two created Foundry accounts."
  value       = azurerm_cognitive_account.foundry[*].id
}

output "key_vault_name" {
  description = "Key Vault holding the LiteLLM secrets."
  value       = azurerm_key_vault.kv.name
}

output "database_persistence_enabled" {
  description = "Whether the test app is wired to the private Postgres (virtual keys/budgets)."
  value       = var.test_app_use_database
}

