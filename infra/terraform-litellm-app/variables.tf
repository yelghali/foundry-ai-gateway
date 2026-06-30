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
#  How to reference the existing infra
#  Default: read the sibling terraform-litellm state file. For real partner infra,
#  point infra_state_path at their state, OR switch the data source in main.tf to
#  a remote backend / pass the infra values as variables.
###############################################################################

variable "infra_state_path" {
  description = "Path to the infra Terraform state to read outputs from. Leave EMPTY to provide the infra references explicitly via the variables below (TF_VAR_* env vars or a tfvars file) — no access to the partner's state required."
  type        = string
  default     = "../terraform-litellm/terraform.tfstate"
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
