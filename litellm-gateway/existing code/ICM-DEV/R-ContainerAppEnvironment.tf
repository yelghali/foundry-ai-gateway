resource "azurerm_container_app_environment" "ContainerAppEnvironment" {
  provider                                    = azurerm.miroki-dev
//  dapr_application_insights_connection_string = "" # Masked sensitive attribute
//  infrastructure_resource_group_name          = "rg-miroki-dev-frc-01"
  infrastructure_subnet_id                    = "/subscriptions/ed0c2c14-ba08-41b3-9cab-561f55ee40b4/resourceGroups/rg-miroki-network-dev-frc-01/providers/Microsoft.Network/virtualNetworks/vnet-miroki-dev-frc-01/subnets/snet-appintegration"
  internal_load_balancer_enabled              = true
  location                                    = "francecentral"
  log_analytics_workspace_id                  = "/subscriptions/ed0c2c14-ba08-41b3-9cab-561f55ee40b4/resourceGroups/rg-miroki-monitoring-dev-frc-01/providers/Microsoft.OperationalInsights/workspaces/log-icm-miroki-dev-frc-01"
//  logs_destination                            = "log-analytics"
  mutual_tls_enabled                          = false
  name                                        = "cae-icm-miroki-dev-frc-01"
//  public_network_access                       = "Disabled"
  resource_group_name                         = "rg-miroki-dev-frc-01"
  tags = {
    Environment = "DEV"
    Application = "Miroki"
  }
  zone_redundancy_enabled = false
  workload_profile {
    maximum_count         = 0
    minimum_count         = 0
    name                  = "Consumption"
    workload_profile_type = "Consumption"
  }
  depends_on = [azurerm_log_analytics_workspace.LogAnalyticsWorkspace]  
}
