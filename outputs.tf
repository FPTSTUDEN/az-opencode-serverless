output "opencode_url" {
  value = "https://${azurerm_container_app.opencode.ingress[0].fqdn}"
}

output "acr_name" {
  value = azurerm_container_registry.acr.name
}

output "resource_group_name" {
  value = azurerm_resource_group.rg.name
}

output "storage_account_name" {
  value = azurerm_storage_account.sa.name
}

output "opencode_config_container_name" {
  value = azurerm_storage_container.opencode_config.name
}

output "opencode_session_container_name" {
  value = azurerm_storage_container.opencode_sessions.name
}
