variable "location"        { type = string }
variable "resource_prefix" { type = string  } #default = "oh" }
variable "foundry_resource" { type = string } # <resource> in the endpoint
variable "deployment_name"  { type = string } # model deployment in Foundry
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