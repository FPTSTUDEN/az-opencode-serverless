output "opencode_url" {
  value = "https://${azurerm_container_app.opencode.ingress[0].fqdn}"
}

output "opencode_smb_test_url" {
  value = "https://${azurerm_container_app.opencode_smb_test.ingress[0].fqdn}"
}

output "acr_name" {
  value = azurerm_container_registry.acr.name
}