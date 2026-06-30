provider "azurerm" {
  # azurerm v4 requires an explicit subscription id (or ARM_SUBSCRIPTION_ID env var).
  subscription_id = var.subscription_id

  features {
    key_vault {
      # Let `terraform destroy` fully remove the vault in a lab/POC.
      purge_soft_delete_on_destroy = true
    }
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
  }
}
