resource "azurerm_log_analytics_workspace" "LogAnalyticsWorkspace" {
  provider                                = azurerm.miroki-dev
  allow_resource_only_permissions         = true
  cmk_for_query_forced                    = false
  daily_quota_gb                          = -1
//  data_collection_rule_id                 = ""
  immediate_data_purge_on_30_days_enabled = false
  internet_ingestion_enabled              = true
  internet_query_enabled                  = true
  location                                = "francecentral"
  name                                    = "log-icm-miroki-dev-frc-01"
//  primary_shared_key                      = "" # Masked sensitive attribute
  resource_group_name                     = "rg-miroki-monitoring-dev-frc-01"
  retention_in_days                       = 30
//  secondary_shared_key                    = "" # Masked sensitive attribute
  sku                                     = "PerGB2018"
  tags = {
    Environment = "DEV"
    Application = "Miroki"
    Service     = "Monitor"
  }
}