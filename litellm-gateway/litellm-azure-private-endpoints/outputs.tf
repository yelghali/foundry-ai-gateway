output "private_ingress" {
  description = "Whether the LiteLLM ingress is internal (true) or public (false). Backends are always private."
  value       = var.private_ingress
}

output "private_endpoint_enabled" {
  description = "Whether LiteLLM is fronted by a Private Endpoint (public network access disabled)."
  value       = var.private_endpoint_enabled
}

output "litellm_private_endpoint_ip" {
  description = "Private IP of the Container Apps environment Private Endpoint (only when private_endpoint_enabled = true). This is the IP the app FQDN resolves to over the VPN / peered VNets."
  value       = var.private_endpoint_enabled ? azurerm_private_endpoint.aca[0].private_service_connection[0].private_ip_address : null
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
