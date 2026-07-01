resource "azurerm_postgresql_flexible_server" "PostgrSQLDatabase" {
  provider                          = azurerm.miroki-dev
  administrator_login               = "litellmuser"
  administrator_password            = "REDACTED-SET-VIA-TF_VAR-OR-KEYVAULT" # do NOT commit the real password
//  administrator_password_wo_version = 0
  auto_grow_enabled                 = false
  backup_retention_days             = 7
  delegated_subnet_id               = "/subscriptions/ed0c2c14-ba08-41b3-9cab-561f55ee40b4/resourceGroups/rg-miroki-network-dev-frc-01/providers/Microsoft.Network/virtualNetworks/vnet-miroki-dev-frc-01/subnets/snet-database"
  geo_redundant_backup_enabled      = false
  location                          = "francecentral"
  name                              = "psql-icm-miroki-dev-frc-01"
//  point_in_time_restore_time_in_utc = ""
  private_dns_zone_id               = "/subscriptions/a97f4651-d442-4661-8da7-1c5a60b32331/resourceGroups/rg-private-dns-zones-shd-frc-01/providers/Microsoft.Network/privateDnsZones/privatelink.postgres.database.azure.com"
  public_network_access_enabled     = false
//  replication_role                  = ""
  resource_group_name               = "rg-miroki-dev-frc-01"
  sku_name                          = "GP_Standard_D2ds_v4"
//  source_server_id                  = ""
  storage_mb                        = 32768
  storage_tier                      = "P4"
  tags = {
    Environment = "DEV"
    Application = "Miroki"
  }
  version = "16"
  zone    = "2"
  authentication {
    active_directory_auth_enabled = true
    password_auth_enabled         = true
    tenant_id                     = "5e9b7433-3d35-4140-b313-5c5ba7a35510"
  }
//  identity {
//    identity_ids = []
//    type         = "SystemAssigned"
//  }
}
