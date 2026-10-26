terraform {
  required_providers {
    azurerm = { source = "hashicorp/azurerm", version = "~> 4.0" }
  }
}

provider "azurerm" {
  features {}
}

data "azurerm_client_config" "current" {}

locals {
  name = "${var.resource_prefix}${substr(md5(data.azurerm_client_config.current.subscription_id), 0, 6)}"
}

resource "azurerm_resource_group" "rg" {
  name     = "${local.name}-rg"
  location = var.location
}

resource "azurerm_container_registry" "acr" {
  name                = "${local.name}acr"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  sku                 = "Basic"
  admin_enabled       = false
}

resource "azurerm_storage_account" "sa" {
  name                     = "${local.name}sa"
  resource_group_name      = azurerm_resource_group.rg.name
  location                 = azurerm_resource_group.rg.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
}

resource "azurerm_storage_share" "workspace" {
  name               = "workspace"
  storage_account_id = azurerm_storage_account.sa.id
  quota              = 50
}

data "azurerm_container_app_environment" "shared" {
  name                = "azure-xiaoxi-siyuan-env"
  resource_group_name = "rg-siyuan-prod"
}

resource "azurerm_container_app_environment_storage" "workspace" {
  name                         = "opencode-workspace"
  container_app_environment_id = data.azurerm_container_app_environment.shared.id
  account_name                 = azurerm_storage_account.sa.name
  share_name                   = azurerm_storage_share.workspace.name
  access_key                   = azurerm_storage_account.sa.primary_access_key
  access_mode                  = "ReadWrite"
}

resource "azurerm_user_assigned_identity" "app" {
  name                = "${local.name}-id"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
}

resource "azurerm_role_assignment" "acr_pull" {
  scope                = azurerm_container_registry.acr.id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_user_assigned_identity.app.principal_id
}

resource "azurerm_container_app" "opencode" {
  name                         = "opencode"
  resource_group_name          = azurerm_resource_group.rg.name
  container_app_environment_id = data.azurerm_container_app_environment.shared.id
  revision_mode                = "Single"

  depends_on = [azurerm_role_assignment.acr_pull, azurerm_container_app_environment_storage.workspace]

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.app.id]
  }

  registry {
    server   = azurerm_container_registry.acr.login_server
    identity = azurerm_user_assigned_identity.app.id
  }

  secret {
    name  = "azure-key"
    value = var.foundry_api_key
  }
  secret {
    name  = "gh-token"
    value = var.gh_pat
  }
  secret {
    name  = "ui-pass"
    value = var.ui_password
  }

  ingress {
    external_enabled = true
    target_port      = 4096
    transport        = "auto"
    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }

  template {
    min_replicas = 1
    max_replicas = 1

    container {
      name   = "opencode"
      image  = "${azurerm_container_registry.acr.login_server}/opencode:latest"
      cpu    = 1
      memory = "2Gi"

      env {
        name        = "AZURE_API_KEY"
        secret_name = "azure-key"
      }
      env {
        name        = "GITHUB_TOKEN"
        secret_name = "gh-token"
      }
      env {
        name        = "OPENCODE_SERVER_PASSWORD"
        secret_name = "ui-pass"
      }

      volume_mounts {
        name = "workspace"
        path = "/workspace"
      }
    }

    volume {
      name         = "workspace"
      storage_name = azurerm_container_app_environment_storage.workspace.name
      storage_type = "AzureFile"
    }
  }
}