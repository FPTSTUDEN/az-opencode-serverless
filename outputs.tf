output "opencode_url" {
  value = "https://${azurerm_container_app.opencode.ingress[0].fqdn}"
}