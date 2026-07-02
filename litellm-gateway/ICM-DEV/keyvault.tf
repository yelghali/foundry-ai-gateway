###############################################################################
#  Key Vault (RBAC) + LiteLLM secrets. ALWAYS PRIVATE: "selected networks"
#  (default Deny) + a private endpoint the app reads over. The deployer's IP is
#  allow-listed so THIS run can write the secrets (public_network_access stays
#  enabled only so the IP rule + AzureServices bypass apply; nothing else can
#  reach it). To go fully private later, set public_network_access_enabled=false
#  and run Terraform from inside the VNet.
###############################################################################

resource "azurerm_key_vault" "kv" {
  name                          = "kv-${var.name_prefix}-${local.suffix}"
  resource_group_name           = var.resource_group_name
  location                      = var.location
  tenant_id                     = data.azurerm_client_config.current.tenant_id
  sku_name                      = "standard"
  rbac_authorization_enabled    = true
  purge_protection_enabled      = false
  public_network_access_enabled = true
  tags                          = var.tags

  network_acls {
    default_action = "Deny"
    bypass         = "AzureServices"
    ip_rules       = local.kv_ip_rules
  }
}

resource "azurerm_role_assignment" "deployer_kv_officer" {
  scope                = azurerm_key_vault.kv.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = data.azurerm_client_config.current.object_id
}

resource "azurerm_role_assignment" "identity_kv_secrets_user" {
  scope                = azurerm_key_vault.kv.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.litellm.principal_id
}

resource "time_sleep" "kv_rbac" {
  depends_on      = [azurerm_role_assignment.deployer_kv_officer]
  create_duration = "30s"
}

resource "azurerm_key_vault_secret" "master_key" {
  name         = "litellm-master-key"
  value        = "sk-${random_password.master_key.result}"
  key_vault_id = azurerm_key_vault.kv.id
  depends_on   = [time_sleep.kv_rbac]
}

resource "azurerm_key_vault_secret" "salt_key" {
  name         = "litellm-salt-key"
  value        = random_password.salt_key.result
  key_vault_id = azurerm_key_vault.kv.id
  depends_on   = [time_sleep.kv_rbac]
}

resource "azurerm_key_vault_secret" "database_url" {
  name         = "database-url"
  value        = local.database_url
  key_vault_id = azurerm_key_vault.kv.id
  depends_on   = [time_sleep.kv_rbac]
}

# Private endpoint (always) — the app reads secrets over this.
resource "azurerm_private_endpoint" "kv" {
  name                = "pe-${azurerm_key_vault.kv.name}"
  location            = var.location
  resource_group_name = var.resource_group_name
  subnet_id           = var.private_endpoint_subnet_id
  tags                = var.tags

  private_service_connection {
    name                           = "psc-${azurerm_key_vault.kv.name}"
    private_connection_resource_id = azurerm_key_vault.kv.id
    subresource_names              = ["vault"]
    is_manual_connection           = false
  }

  dynamic "private_dns_zone_group" {
    for_each = var.manage_pe_dns ? [1] : []
    content {
      name                 = "default"
      private_dns_zone_ids = [var.private_dns_zone_id_vault]
    }
  }
}
