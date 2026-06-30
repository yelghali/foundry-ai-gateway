###############################################################################
#  App-only module: deploy LiteLLM on top of EXISTING infra.
#  Reads the infra outputs (Foundries, PostgreSQL, Key Vault, ACA environment,
#  managed identity + role assignments) and creates only the LiteLLM Container App.
#  Does NOT modify the partner's infra state.
###############################################################################

variable "subscription_id" {
  description = "Azure subscription id (same as the infra)."
  type        = string
}

###############################################################################
#  How to reference the existing infra — pick ONE of three sources:
#
#    infra_state_backend = "local"    -> read a local state file (infra_state_path)
#    infra_state_backend = "azurerm"  -> read remote state in an Azure Storage
#                                        blob   (infra_state_config)
#    infra_state_backend = "none"     -> read NO state; supply the infra values
#                                        explicitly via the variables below
#                                        (tfvars or TF_VAR_* env vars)
#
#  Precedence inside the module: bootstrap-created -> infra state -> explicit var.
#  (When bootstrap = true the infra state is ignored entirely.)
###############################################################################

variable "infra_state_backend" {
  description = "Where the infra Terraform state lives: 'local' (a state file on disk), 'azurerm' (remote state in an Azure Storage blob), or 'none' (no state — pass the infra references explicitly via the variables below / TF_VAR_* env vars)."
  type        = string
  default     = "local"
  validation {
    condition     = contains(["local", "azurerm", "none"], var.infra_state_backend)
    error_message = "infra_state_backend must be one of: local, azurerm, none."
  }
}

variable "infra_state_path" {
  description = "LOCAL backend only: path to the infra Terraform state file. Set to \"\" (or use infra_state_backend = \"none\") to skip reading state and provide the infra references explicitly."
  type        = string
  default     = "../terraform-litellm/terraform.tfstate"
}

variable "infra_state_config" {
  description = "AZURERM (remote) backend only: config for the infra state blob, e.g. { resource_group_name = \"rg-tfstate\", storage_account_name = \"sttfstate\", container_name = \"tfstate\", key = \"litellm-infra.tfstate\" }. Add use_azuread_auth = \"true\" to authenticate with your Entra login instead of a storage key."
  type        = map(string)
  default     = {}
}

###############################################################################
#  Explicit infra references — used when infra_state_path = "".
#  Supply via -var, a *.tfvars file, or TF_VAR_<name> environment variables.
###############################################################################

variable "resource_group_name" {
  description = "Resource group that holds the infra (and where the app is created)."
  type        = string
  default     = ""
}

variable "location" {
  description = "Location for the container app."
  type        = string
  default     = "eastus2"
}

variable "container_app_name" {
  description = "Name to give the LiteLLM Container App."
  type        = string
  default     = "ca-litellm"
}

variable "container_app_environment_id" {
  description = "Resource id of the existing Container Apps environment."
  type        = string
  default     = ""
}

variable "identity_id" {
  description = "Resource id of the existing user-assigned managed identity (must have Cognitive Services User on the Foundries + Key Vault Secrets User)."
  type        = string
  default     = ""
}

variable "identity_client_id" {
  description = "Client id of that managed identity (AZURE_CLIENT_ID)."
  type        = string
  default     = ""
}

variable "master_key_secret_uri" {
  description = "Key Vault secret URI (versionless) for the LiteLLM master key."
  type        = string
  default     = ""
}

variable "database_url_secret_uri" {
  description = "Key Vault secret URI (versionless) for the PostgreSQL connection string."
  type        = string
  default     = ""
}

variable "foundry_api_bases" {
  description = "The two regional Foundry Azure OpenAI endpoints to load balance across."
  type        = list(string)
  default     = []
}

variable "api_version" {
  description = "Azure OpenAI API version."
  type        = string
  default     = "2024-10-21"
}

variable "model_deployment_name" {
  description = "Azure deployment name of the model (azure/<this>)."
  type        = string
  default     = "gpt-4.1"
}

variable "public_model_name" {
  description = "Client-facing model name exposed by LiteLLM."
  type        = string
  default     = "gpt-4.1"
}

variable "litellm_master_key" {
  description = "Master key value (only needed for the test/key scripts' outputs; the container reads it from Key Vault)."
  type        = string
  default     = ""
  sensitive   = true
}

###############################################################################
#  BOOTSTRAP mode — deploy onto MINIMAL infra (only ACA env + PostgreSQL + Key
#  Vault exist; no identity, no RBAC, no secrets yet). When bootstrap = true the
#  module ALSO creates the managed identity, assigns roles (Cognitive Services
#  User on the Foundries + Key Vault Secrets User on the vault), generates the
#  master key, and writes the master key + DATABASE_URL secrets into the vault.
#  Set infra_state_path = "" and provide the values below.
###############################################################################

variable "bootstrap" {
  description = "Create identity + role assignments + Key Vault secrets on top of minimal infra (ACA env + Postgres + Key Vault)."
  type        = bool
  default     = false
}

variable "name_prefix" {
  description = "Prefix for the created managed identity (bootstrap)."
  type        = string
  default     = "litellm"
}

variable "key_vault_name" {
  description = "Name of the EXISTING Key Vault to write the master key + DATABASE_URL secrets into and grant the identity access (bootstrap)."
  type        = string
  default     = ""
}

variable "foundry_account_ids" {
  description = "Resource IDs of the EXISTING Foundry (Cognitive Services) accounts to grant the identity 'Cognitive Services User' on (bootstrap)."
  type        = list(string)
  default     = []
}

variable "postgres_fqdn" {
  description = "FQDN of the EXISTING PostgreSQL Flexible Server (bootstrap) — used to build DATABASE_URL."
  type        = string
  default     = ""
}

variable "pg_admin_login" {
  description = "PostgreSQL admin login (bootstrap) — used to build DATABASE_URL when database_url is not given."
  type        = string
  default     = "litellmadmin"
}

variable "pg_admin_password" {
  description = "PostgreSQL admin password (bootstrap) — used to build DATABASE_URL when database_url is not given. Best supplied as an env var (TF_VAR_pg_admin_password) or pulled from the infra state output 'postgres_admin_password'. Ignored if database_url is set."
  type        = string
  default     = ""
  sensitive   = true
}

variable "pg_database" {
  description = "PostgreSQL database name for LiteLLM (bootstrap)."
  type        = string
  default     = "litellm"
}

variable "pg_port" {
  description = "PostgreSQL port (bootstrap)."
  type        = string
  default     = "5432"
}

variable "pg_sslmode" {
  description = "PostgreSQL sslmode for the connection string (bootstrap). Azure Flexible Server requires 'require'."
  type        = string
  default     = "require"
}

variable "database_url" {
  description = "FULL PostgreSQL connection string for LiteLLM (bootstrap). If set, it is written to Key Vault as-is and the pg_* component vars are ignored. Use this when the existing server already has a known connection string / different credentials. Best supplied via env var TF_VAR_database_url (e.g. from `terraform -chdir=../terraform-litellm output -raw ...`) so the secret never lands in a file."
  type        = string
  default     = ""
  sensitive   = true
}

###############################################################################
#  LiteLLM container settings
###############################################################################

variable "litellm_image" {
  description = "LiteLLM proxy container image. Defaults to the infra-provided image."
  type        = string
  default     = ""
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

variable "tags" {
  description = "Tags applied to the container app."
  type        = map(string)
  default = {
    workload = "litellm-gateway"
    managed  = "terraform-app"
  }
}
