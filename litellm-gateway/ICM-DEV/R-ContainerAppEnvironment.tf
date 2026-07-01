###############################################################################
#  ADDED: a NEW PUBLIC test Container Apps environment (throwaway).
#  Public ingress so you can hit LiteLLM directly. VNet-integrated ONLY when a
#  dedicated infra subnet is supplied (needed to reach the private Postgres when
#  test_app_use_database = true). Delete this env + app after testing.
###############################################################################

resource "azurerm_container_app_environment" "test" {
  provider                   = azurerm.miroki-dev
  name                       = var.test_env_name
  location                   = var.location
  resource_group_name        = var.resource_group_name
  log_analytics_workspace_id = data.azurerm_log_analytics_workspace.existing.id

  # VNet-integrate when a dedicated subnet is provided (default: snet-private-endpoints)
  # so the app can reach the PRIVATE Postgres. Ingress stays PUBLIC (external) because
  # internal_load_balancer_enabled = false. The subnet must be delegated to
  # Microsoft.App/environments (az network vnet subnet update ... --delegations
  # Microsoft.App/environments) and be dedicated to this env.
  # NOTE (azurerm): internal_load_balancer_enabled can ONLY be set together with
  # infrastructure_subnet_id, so both are omitted (null) in the no-subnet case.
  infrastructure_subnet_id       = var.test_env_infra_subnet_id != "" ? var.test_env_infra_subnet_id : null
  internal_load_balancer_enabled = var.test_env_infra_subnet_id != "" ? false : null

  workload_profile {
    name                  = "Consumption"
    workload_profile_type = "Consumption"
    maximum_count         = 0
    minimum_count         = 0
  }

  tags = var.tags
}

