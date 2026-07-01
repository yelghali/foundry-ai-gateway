###############################################################################
#  ADDED: Key Vault holding the LiteLLM master key, salt key, and DB URL.
#  RBAC-authorized. The container-app identity reads them (Key Vault Secrets
#  User); this Terraform run writes them (Key Vault Secrets Officer).
###############################################################################

resource "random_password" "master_key" {
  length  = 40
  special = false
}

resource "random_password" "salt_key" {
  length  = 32
  special = false
}

resource "azurerm_key_vault" "kv" {
  provider                      = azurerm.miroki-dev
  name                          = var.key_vault_name
  resource_group_name           = var.resource_group_name
  location                      = var.location
  tenant_id                     = data.azurerm_client_config.current.tenant_id
  sku_name                      = "standard"
  enable_rbac_authorization     = true
  purge_protection_enabled      = false
  public_network_access_enabled = var.key_vault_public_access
  tags                          = var.tags

  network_acls {
    default_action = var.key_vault_public_access ? "Allow" : "Deny"
    bypass         = "AzureServices"
  }
}

# Deployer can write secrets during apply.
resource "azurerm_role_assignment" "deployer_kv_officer" {
  provider             = azurerm.miroki-dev
  scope                = azurerm_key_vault.kv.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = data.azurerm_client_config.current.object_id
}

# Container-app identity can read secrets (used by the ACA Key Vault references).
resource "azurerm_role_assignment" "identity_kv_secrets_user" {
  provider             = azurerm.miroki-dev
  scope                = azurerm_key_vault.kv.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = data.azurerm_user_assigned_identity.existing.principal_id
}

# RBAC is eventually consistent; wait before writing secrets.
resource "time_sleep" "kv_rbac" {
  depends_on      = [azurerm_role_assignment.deployer_kv_officer]
  create_duration = "30s"
}

resource "azurerm_key_vault_secret" "master_key" {
  provider     = azurerm.miroki-dev
  name         = "litellm-master-key"
  value        = "sk-${random_password.master_key.result}"
  key_vault_id = azurerm_key_vault.kv.id
  depends_on   = [time_sleep.kv_rbac]
}

resource "azurerm_key_vault_secret" "salt_key" {
  provider     = azurerm.miroki-dev
  count        = var.test_app_use_database ? 1 : 0
  name         = "litellm-salt-key"
  value        = random_password.salt_key.result
  key_vault_id = azurerm_key_vault.kv.id
  depends_on   = [time_sleep.kv_rbac]
}

resource "azurerm_key_vault_secret" "database_url" {
  provider     = azurerm.miroki-dev
  count        = var.test_app_use_database ? 1 : 0
  name         = "database-url"
  value        = local.database_url
  key_vault_id = azurerm_key_vault.kv.id
  depends_on   = [time_sleep.kv_rbac]
}

###############################################################################
#  Private endpoint for the Key Vault.
###############################################################################

resource "azurerm_private_endpoint" "kv" {
  provider = azurerm.miroki-dev
  count    = var.enable_private_endpoints ? 1 : 0

  name                = "pe-${var.key_vault_name}"
  location            = var.location
  resource_group_name = var.resource_group_name
  subnet_id           = var.private_endpoint_subnet_id
  tags                = var.tags

  private_service_connection {
    name                           = "psc-${var.key_vault_name}"
    private_connection_resource_id = azurerm_key_vault.kv.id
    subresource_names              = ["vault"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = [var.private_dns_zone_id_vault]
  }
}
