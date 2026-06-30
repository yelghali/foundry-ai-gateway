###############################################################################
#  Required
###############################################################################

variable "subscription_id" {
  description = "Azure subscription id to deploy into."
  type        = string
}

###############################################################################
#  Resource group / naming / location
###############################################################################

variable "create_resource_group" {
  description = "Create a new resource group (true) or use an existing one (false)."
  type        = bool
  default     = true
}

variable "resource_group_name" {
  description = "Name of the resource group to create or reuse."
  type        = string
  default     = "rg-litellm-gateway"
}

variable "location" {
  description = "Location for the regionless resources (Key Vault, Postgres, ACA env, identity)."
  type        = string
  default     = "eastus2"
}

variable "name_prefix" {
  description = "Short prefix used in resource names. Keep <= 10 chars (Key Vault name limit)."
  type        = string
  default     = "litellm"

  validation {
    condition     = length(var.name_prefix) <= 10 && can(regex("^[a-z0-9]+$", var.name_prefix))
    error_message = "name_prefix must be <= 10 lowercase alphanumeric characters."
  }
}

variable "tags" {
  description = "Tags applied to all resources."
  type        = map(string)
  default = {
    workload = "litellm-gateway"
    managed  = "terraform"
  }
}

###############################################################################
#  Foundry backends (the two regions LiteLLM load balances across)
###############################################################################

variable "create_foundries" {
  description = "Create two Azure AI Foundry accounts + a GPT-4 deployment each (true), or point at existing endpoints (false)."
  type        = bool
  default     = true
}

variable "foundry_regions" {
  description = "Exactly two regions, one Foundry account per region. Used only when create_foundries = true."
  type        = list(string)
  default     = ["eastus2", "swedencentral"]

  validation {
    condition     = length(var.foundry_regions) == 2
    error_message = "Provide exactly two regions (LiteLLM load balances across two backends)."
  }
}

variable "existing_foundry_api_bases" {
  description = "Used only when create_foundries = false. Exactly two Azure OpenAI endpoints, e.g. https://acct.openai.azure.com/ . You must grant the LiteLLM identity 'Cognitive Services User' on them yourself."
  type        = list(string)
  default     = []
}

variable "model_deployment_name" {
  description = "Azure deployment name for the GPT-4 model (LiteLLM calls azure/<this>). Must match on both Foundries."
  type        = string
  default     = "gpt-4.1"
}

variable "public_model_name" {
  description = "Client-facing model name exposed by LiteLLM (what callers pass as \"model\")."
  type        = string
  default     = "gpt-4.1"
}

variable "model_name" {
  description = "Underlying Azure OpenAI model name to deploy."
  type        = string
  default     = "gpt-4.1"
}

variable "model_version" {
  description = "Underlying model version to deploy."
  type        = string
  default     = "2025-04-14"
}

variable "model_sku_name" {
  description = "Deployment SKU (GlobalStandard, Standard, ...)."
  type        = string
  default     = "GlobalStandard"
}

variable "model_capacity" {
  description = "Deployment capacity in K TPM on each Foundry."
  type        = number
  default     = 50
}

variable "api_version" {
  description = "Azure OpenAI API version LiteLLM uses to call the deployments."
  type        = string
  default     = "2024-10-21"
}

###############################################################################
#  PostgreSQL Flexible Server
###############################################################################

variable "pg_admin_login" {
  description = "PostgreSQL administrator login."
  type        = string
  default     = "litellmadmin"
}

variable "pg_sku_name" {
  description = "PostgreSQL Flexible Server SKU."
  type        = string
  default     = "B_Standard_B1ms"
}

variable "pg_storage_mb" {
  description = "PostgreSQL Flexible Server storage in MB."
  type        = number
  default     = 32768
}

variable "pg_version" {
  description = "PostgreSQL major version."
  type        = string
  default     = "16"
}

variable "pg_location" {
  description = "Region for the PostgreSQL Flexible Server. Defaults to var.location; override if your subscription is offer-restricted for Postgres in that region (LocationIsOfferRestricted)."
  type        = string
  default     = null
}

###############################################################################
#  LiteLLM container
###############################################################################

variable "litellm_image" {
  description = "LiteLLM proxy container image."
  type        = string
  default     = "ghcr.io/berriai/litellm:main-stable"
}

variable "litellm_cpu" {
  description = "vCPU for the LiteLLM container."
  type        = number
  default     = 1.0
}

variable "litellm_memory" {
  description = "Memory for the LiteLLM container."
  type        = string
  default     = "2Gi"
}

variable "deploy_litellm_app" {
  description = "Let Terraform also deploy the LiteLLM Container App (true). Set false to keep this config infra-only and deploy the app with the separate ../terraform-litellm-app module instead."
  type        = bool
  default     = true
}

variable "vanilla" {
  description = "Produce VANILLA infra only: Foundries + PostgreSQL + (empty) Key Vault + ACA env + Log Analytics, but NO managed identity, NO role assignments, and NO Key Vault secrets. Use this to hand off raw infra and let the app module's `bootstrap` mode create the identity + RBAC + secrets. Implies the app is not deployed here."
  type        = bool
  default     = false
}

###############################################################################
#  Private networking (simulate a locked-down env)
###############################################################################

variable "enable_private_networking" {
  description = "Create a VNet, integrate the ACA environment into it, expose the two Foundries via Private Endpoints (public network access disabled), and let LiteLLM reach them privately. Ingress to LiteLLM stays public so you can test it."
  type        = bool
  default     = false
}

variable "vnet_address_space" {
  description = "Address space for the VNet (only used when enable_private_networking = true)."
  type        = list(string)
  default     = ["10.20.0.0/16"]
}

variable "aca_subnet_prefix" {
  description = "Subnet for the Container Apps environment (delegated to Microsoft.App/environments; /23 minimum for a Consumption environment)."
  type        = string
  default     = "10.20.0.0/23"
}

variable "pe_subnet_prefix" {
  description = "Subnet that holds the Foundry private endpoints."
  type        = string
  default     = "10.20.2.0/24"
}
