resource "azurerm_application_insights" "ApplicationInsights" {
  provider                              = azurerm.miroki-dev
  application_type                      = "web"
  //connection_string                     = "" # Masked sensitive attribute
  daily_data_cap_in_gb                  = 100
  daily_data_cap_notifications_disabled = false
  disable_ip_masking                    = false
  force_customer_storage_for_profiler   = false
  //instrumentation_key                   = "" # Masked sensitive attribute
  internet_ingestion_enabled            = true
  internet_query_enabled                = true
  local_authentication_disabled         = false
  location                              = "francecentral"
  name                                  = "appi-icm-miroki-dev-frc-01"
  resource_group_name                   = "rg-miroki-monitoring-dev-frc-01"
  retention_in_days                     = 90
  sampling_percentage                   = 0
  tags = {
    Environment = "DEV"
    Application = "Miroki"
    Service     = "Monitor"
  }
  workspace_id = "/subscriptions/ed0c2c14-ba08-41b3-9cab-561f55ee40b4/resourceGroups/rg-miroki-monitoring-dev-frc-01/providers/Microsoft.OperationalInsights/workspaces/log-icm-miroki-dev-frc-01"
  depends_on = [azurerm_container_app.ContainerApp,azurerm_log_analytics_workspace.LogAnalyticsWorkspace] 
}
