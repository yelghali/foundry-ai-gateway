terraform {
  required_version = ">= 1.5.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.14.0"
    }
  }
}

provider "azurerm" {
  features {}
}

provider "azurerm" {
  alias           = "connectivity"
  subscription_id = "a97f4651-d442-4661-8da7-1c5a60b32331"

  features {
    resource_group {
       prevent_deletion_if_contains_resources = false
    }
  }
}

provider "azurerm" {
  alias           = "management"
  subscription_id = "b7f5fb75-9029-410f-870f-ba6d2510560d"

  features {
    resource_group {
       prevent_deletion_if_contains_resources = false
    }
  }
}

provider "azurerm" {
  alias           = "identity"
  subscription_id = "xxxxxxxxxxxxxxxxxxxx"

  features {
    resource_group {
       prevent_deletion_if_contains_resources = false
    }
  }
}

provider "azurerm" {
  alias           = "miroki-dev"
  subscription_id = "ed0c2c14-ba08-41b3-9cab-561f55ee40b4"

  features {
    resource_group {
       prevent_deletion_if_contains_resources = false
    }
  }
}

provider "azurerm" {
  alias           = "miroki-prd"
  subscription_id = "4a8cc277-2812-461a-a950-d818a496cac1"

  features {
    resource_group {
       prevent_deletion_if_contains_resources = false
    }
  }
}