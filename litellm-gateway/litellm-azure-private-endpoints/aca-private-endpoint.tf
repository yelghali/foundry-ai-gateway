###############################################################################
#  Private Endpoint for the Container Apps environment (LiteLLM gateway).
#
#  Created ONLY when private_endpoint_enabled = true. It puts LiteLLM behind a
#  Private Link so it is reachable exclusively from private networks:
#    - the local spoke VNet,
#    - peered spokes,
#    - and on-premises over the hub VPN/ExpressRoute (hub-and-spoke).
#
#  The environment's public network access is turned off in containerapp.tf.
#  The app keeps the SAME FQDN (ca-...<region>.azurecontainerapps.io); it now
#  resolves to this PE's private IP through the shared
#  privatelink.<region>.azurecontainerapps.io zone (var.private_dns_zone_id_aca).
#
#  Subresource is "managedEnvironments" (plural) for Microsoft.App environments.
###############################################################################

resource "azurerm_private_endpoint" "aca" {
  count = var.private_endpoint_enabled ? 1 : 0

  name                = "pe-${azurerm_container_app_environment.cae.name}"
  location            = var.location
  resource_group_name = var.resource_group_name
  subnet_id           = var.private_endpoint_subnet_id
  tags                = var.tags

  private_service_connection {
    name                           = "psc-${azurerm_container_app_environment.cae.name}"
    private_connection_resource_id = azurerm_container_app_environment.cae.id
    subresource_names              = ["managedEnvironments"]
    is_manual_connection           = false
  }

  # When manage_pe_dns = true, Terraform writes the wildcard A record
  # (*.<envDefaultDomain>) into the shared privatelink.<region>.azurecontainerapps.io
  # zone. Set false to let a landing-zone DINE policy register the record.
  dynamic "private_dns_zone_group" {
    for_each = var.manage_pe_dns ? [1] : []
    content {
      name                 = "default"
      private_dns_zone_ids = [var.private_dns_zone_id_aca]
    }
  }
}
