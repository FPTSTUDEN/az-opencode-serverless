variable "location" { type = string }
variable "resource_prefix" { type = string } #default = "oh" }

variable "environment_mode" {
  type        = string
  description = "Use the existing shared ACA environment or create a dedicated one."
  default     = "dedicated"

  validation {
    condition     = contains(["shared", "dedicated"], var.environment_mode)
    error_message = "environment_mode must be either shared or dedicated."
  }
}

variable "shared_environment_name" {
  type    = string
  default = "azure-xiaoxi-siyuan-env"
}

variable "shared_environment_resource_group" {
  type    = string
  default = "rg-siyuan-prod"
}

variable "foundry_resource" { type = string } # <resource> in the endpoint
variable "deployment_name" { type = string }  # model deployment in Foundry
variable "foundry_api_key" {
  type      = string
  sensitive = true
}
variable "gh_pat" {
  type      = string
  sensitive = true
}
variable "ui_password" {
  type      = string
  sensitive = true
}