output "private_ingress" {
  description = "Whether the LiteLLM ingress is internal (true) or public (false). Backends are always private."
  value       = var.private_ingress
}

output "litellm_fqdn" {
  description = "Gateway FQDN. PUBLIC when private_ingress = false; a VNet-private FQDN when true."
  value       = azurerm_container_app.litellm.ingress[0].fqdn
}

output "litellm_url" {
  description = "Gateway URL."
  value       = "https://${azurerm_container_app.litellm.ingress[0].fqdn}"
}

output "litellm_master_key" {
  description = "Master key callers present to LiteLLM (also in Key Vault)."
  value       = azurerm_key_vault_secret.master_key.value
  sensitive   = true
}

output "public_model_name" {
  value = var.public_model_name
}

output "foundry_api_bases" {
  value = local.foundry_api_bases
}

output "foundry_account_ids" {
  value = azurerm_cognitive_account.foundry[*].id
}

output "key_vault_name" {
  value = azurerm_key_vault.kv.name
}

output "postgres_fqdn" {
  value = azurerm_postgresql_flexible_server.pg.fqdn
}
