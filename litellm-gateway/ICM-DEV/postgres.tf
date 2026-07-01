###############################################################################
#  PostgreSQL Flexible Server — ALWAYS private (VNet-injected into snet-database
#  + shared private DNS zone). The VNet-integrated ACA env reaches it by FQDN in
#  both public and private modes.
###############################################################################

resource "azurerm_postgresql_flexible_server" "pg" {
  name                          = "psql-${var.name_prefix}-${local.suffix}"
  resource_group_name           = var.resource_group_name
  location                      = var.location
  version                       = var.pg_version
  administrator_login           = var.pg_admin_login
  administrator_password        = random_password.pg.result
  sku_name                      = var.pg_sku_name
  storage_mb                    = var.pg_storage_mb
  delegated_subnet_id           = var.postgres_delegated_subnet_id
  private_dns_zone_id           = var.private_dns_zone_id_postgres
  public_network_access_enabled = false
  tags                          = var.tags

  authentication {
    password_auth_enabled = true
  }

  lifecycle {
    ignore_changes = [zone]
  }
}

resource "azurerm_postgresql_flexible_server_database" "litellm" {
  name      = var.pg_database
  server_id = azurerm_postgresql_flexible_server.pg.id
  charset   = "UTF8"
  collation = "en_US.utf8"
}
