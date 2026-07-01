resource "azurerm_container_app" "ContainerApp" {
  provider                      = azurerm.miroki-dev
  container_app_environment_id  = "/subscriptions/ed0c2c14-ba08-41b3-9cab-561f55ee40b4/resourceGroups/rg-miroki-dev-frc-01/providers/Microsoft.App/managedEnvironments/cae-icm-miroki-dev-frc-01"
//  custom_domain_verification_id = "" # Masked sensitive attribute
  max_inactive_revisions        = 100
  name                          = "ca-icm-miroki-dev-frc-01"
  resource_group_name           = "rg-miroki-dev-frc-01"
  revision_mode                 = "Single"
  tags = {
    Environment = "DEV"
    Application = "Miroki"
  }
  workload_profile_name = "Consumption"
  identity {
    identity_ids = ["/subscriptions/ed0c2c14-ba08-41b3-9cab-561f55ee40b4/resourceGroups/rg-miroki-dev-frc-01/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-ca-icm-miroki-dev-frc-01"]
    type         = "UserAssigned"
  }
  ingress {
    allow_insecure_connections = false
//    client_certificate_mode    = ""
//    exposed_port               = 0
    external_enabled           = true
    target_port                = 80
    transport                  = "auto"
    traffic_weight {
//      label           = ""
      latest_revision = true
      percentage      = 100
//      revision_suffix = ""
    }
  }
  registry {
    identity             = "/subscriptions/ed0c2c14-ba08-41b3-9cab-561f55ee40b4/resourceGroups/rg-miroki-dev-frc-01/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-ca-icm-miroki-dev-frc-01"
    password_secret_name = ""
    server               = "cricmmirokidevfrc01.azurecr.io"
    username             = ""
  }
  template {
//    cooldown_period_in_seconds       = 300
    max_replicas                     = 3
    min_replicas                     = 2
//    polling_interval_in_seconds      = 30
    revision_suffix                  = ""
//    termination_grace_period_seconds = 0
    container {
      args    = []
      command = []
      cpu     = 0.5
      image   = "mcr.microsoft.com/azuredocs/containerapps-helloworld:latest"
      memory  = "1Gi"
      name    = "litellm"
//      env {
//        name        = "LITELLM_MASTER_KEY"
//        secret_name = "litellm-master-key"
//        value       = "REDACTED"
//      }
//      env {
//        name        = "LITELLM_SALT_KEY"
//        secret_name = "litellm-salt-key"
//        value       = "REDACTED"
//      }
//      env {
//        name        = "DATABASE_URL"
//        secret_name = "database-url"
//        value       = ""
//      }
//      env {
//        name        = "STORE_MODEL_IN_DB"
//        secret_name = ""
//        value       = "True"
//      }
    }
  }
  depends_on = [azurerm_container_app_environment.ContainerAppEnvironment,azurerm_user_assigned_identity.ManagedIdentity,azurerm_container_registry.ContainerRegistry]  
}
