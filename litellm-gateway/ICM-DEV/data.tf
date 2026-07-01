###############################################################################
#  Reference the EXISTING infra as DATA SOURCES (no Terraform state required,
#  no "already exists" conflict, and the live resources are never modified).
###############################################################################

# The container-app identity that already exists (reused by the test app + RBAC).
data "azurerm_user_assigned_identity" "existing" {
  provider            = azurerm.miroki-dev
  name                = var.identity_name
  resource_group_name = var.resource_group_name
}

# The existing PRIVATE PostgreSQL Flexible Server (id + fqdn; the LiteLLM DB is
# created on it, and DATABASE_URL is built from its fqdn + the admin password).
data "azurerm_postgresql_flexible_server" "existing" {
  provider            = azurerm.miroki-dev
  name                = var.postgres_server_name
  resource_group_name = var.resource_group_name
}

# The existing Log Analytics workspace (used by the test Container Apps env).
data "azurerm_log_analytics_workspace" "existing" {
  provider            = azurerm.miroki-dev
  name                = var.log_analytics_workspace_name
  resource_group_name = var.monitoring_resource_group_name
}
