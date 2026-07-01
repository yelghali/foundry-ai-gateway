resource "azurerm_container_registry" "ContainerRegistry" {
  provider                      = azurerm.miroki-dev
  admin_enabled                 = true
//  admin_password                = "" # Masked sensitive attribute
  anonymous_pull_enabled        = false
  data_endpoint_enabled         = false
  encryption                    = []
  export_policy_enabled         = true
  location                      = "francecentral"
  name                          = "cricmmirokidevfrc01"
  network_rule_bypass_option    = "AzureServices"
  network_rule_set              = []
  public_network_access_enabled = true
  quarantine_policy_enabled     = false
  resource_group_name           = "rg-miroki-dev-frc-01"
  retention_policy_in_days      = 0
  sku                           = "Standard"
  tags = {
    Environment = "DEV"
    Application = "Miroki"
  }
  trust_policy_enabled    = false
  zone_redundancy_enabled = false
}
