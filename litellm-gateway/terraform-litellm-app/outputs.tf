output "litellm_url" {
  description = "Public HTTPS endpoint of the LiteLLM gateway."
  value       = "https://${azurerm_container_app.litellm.ingress[0].fqdn}"
}

output "litellm_master_key" {
  description = "Master key callers present to LiteLLM (from infra state or var)."
  value       = local.master_key
  sensitive   = true
}

output "public_model_name" {
  description = "Model name callers pass to LiteLLM."
  value       = local.public_model_name
}

output "resource_group_name" {
  description = "Resource group."
  value       = local.rg
}

output "container_app_name" {
  description = "Container App name."
  value       = local.app_name
}
