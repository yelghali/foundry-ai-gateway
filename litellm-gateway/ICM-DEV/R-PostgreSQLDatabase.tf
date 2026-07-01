###############################################################################
#  ADDED: dedicated database for LiteLLM (keys / spend / budgets) on the
#  EXISTING private PostgreSQL Flexible Server. This is a control-plane (ARM)
#  operation, so it works even though the server has no public access.
###############################################################################

resource "azurerm_postgresql_flexible_server_database" "litellm" {
  provider  = azurerm.miroki-dev
  count     = var.test_app_use_database ? 1 : 0
  name      = var.pg_database
  server_id = data.azurerm_postgresql_flexible_server.existing.id
  charset   = "UTF8"
  collation = "en_US.utf8"
}
