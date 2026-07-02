###############################################################################
#  PostgreSQL Flexible Server — ALWAYS PRIVATE.
#  "Public access" networking mode with public access DISABLED + a PRIVATE
#  ENDPOINT (Private Link) in snet-private-endpoints. No delegated subnet / VNet
#  injection. The VNet-integrated ACA env reaches it over the private endpoint.
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

resource "azurerm_private_endpoint" "pg" {
  name                = "pe-${azurerm_postgresql_flexible_server.pg.name}"
  location            = var.location
  resource_group_name = var.resource_group_name
  subnet_id           = var.private_endpoint_subnet_id
  tags                = var.tags

  private_service_connection {
    name                           = "psc-${azurerm_postgresql_flexible_server.pg.name}"
    private_connection_resource_id = azurerm_postgresql_flexible_server.pg.id
    subresource_names              = ["postgresqlServer"]
    is_manual_connection           = false
  }

  dynamic "private_dns_zone_group" {
    for_each = var.manage_pe_dns ? [1] : []
    content {
      name                 = "default"
      private_dns_zone_ids = [var.private_dns_zone_id_postgres]
    }
  }
}
