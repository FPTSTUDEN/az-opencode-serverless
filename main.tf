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
  name                       = "${var.resource_prefix}${substr(md5(data.azurerm_client_config.current.subscription_id), 0, 6)}"
  opencode_config_container  = "opencode-config"
  opencode_session_container = "opencode-sessions"
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

  blob_properties {
    versioning_enabled = true

    delete_retention_policy {
      days = 7
    }

    container_delete_retention_policy {
      days = 7
    }
  }
}

resource "azurerm_storage_share" "workspace" {
  name               = "workspace"
  storage_account_id = azurerm_storage_account.sa.id
  quota              = 50
}

resource "azurerm_storage_container" "opencode_config" {
  name                  = local.opencode_config_container
  storage_account_id    = azurerm_storage_account.sa.id
  container_access_type = "private"
}

resource "azurerm_storage_container" "opencode_sessions" {
  name                  = local.opencode_session_container
  storage_account_id    = azurerm_storage_account.sa.id
  container_access_type = "private"
}

resource "azurerm_storage_management_policy" "opencode_session_versions" {
  storage_account_id = azurerm_storage_account.sa.id

  rule {
    name    = "expire-opencode-session-versions"
    enabled = true

    filters {
      prefix_match = ["${azurerm_storage_container.opencode_sessions.name}/sessions/"]
      blob_types   = ["blockBlob"]
    }

    actions {
      version {
        delete_after_days_since_creation = 30
      }
    }
  }
}

data "azurerm_container_app_environment" "shared" {
  count               = var.environment_mode == "shared" ? 1 : 0
  name                = var.shared_environment_name
  resource_group_name = var.shared_environment_resource_group
}

resource "azurerm_log_analytics_workspace" "law" {
  count               = var.environment_mode == "dedicated" ? 1 : 0
  name                = "${local.name}-law"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  sku                 = "PerGB2018"
  retention_in_days   = 30
}

resource "azurerm_virtual_network" "aca" {
  count               = var.environment_mode == "dedicated" ? 1 : 0
  name                = "${local.name}-vnet"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  address_space       = ["10.0.0.0/16"]
}

resource "azurerm_subnet" "aca" {
  count                = var.environment_mode == "dedicated" ? 1 : 0
  name                 = "container-apps-infrastructure"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.aca[0].name
  address_prefixes     = ["10.0.0.0/27"]

  delegation {
    name = "container-apps-delegation"

    service_delegation {
      name = "Microsoft.App/environments"
      actions = [
        "Microsoft.Network/virtualNetworks/subnets/join/action",
      ]
    }
  }
}

resource "azurerm_container_app_environment" "dedicated" {
  count                      = var.environment_mode == "dedicated" ? 1 : 0
  name                       = "${local.name}-env"
  resource_group_name        = azurerm_resource_group.rg.name
  location                   = azurerm_resource_group.rg.location
  log_analytics_workspace_id = azurerm_log_analytics_workspace.law[0].id
  infrastructure_subnet_id   = azurerm_subnet.aca[0].id

  workload_profile {
    name                  = "Consumption"
    workload_profile_type = "Consumption"
  }
}

locals {
  environment_id = var.environment_mode == "shared" ? data.azurerm_container_app_environment.shared[0].id : azurerm_container_app_environment.dedicated[0].id
}

resource "azurerm_container_app_environment_storage" "workspace" {
  name                         = "opencode-workspace"
  container_app_environment_id = local.environment_id
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

resource "azurerm_role_assignment" "opencode_config_reader" {
  scope                = azurerm_storage_container.opencode_config.id
  role_definition_name = "Storage Blob Data Reader"
  principal_id         = azurerm_user_assigned_identity.app.principal_id
}

resource "azurerm_role_assignment" "opencode_config_publisher" {
  scope                = azurerm_storage_container.opencode_config.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = data.azurerm_client_config.current.object_id
}

resource "azurerm_role_assignment" "opencode_sessions_contributor" {
  scope                = azurerm_storage_container.opencode_sessions.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_user_assigned_identity.app.principal_id
}

resource "azurerm_container_app" "opencode" {
  name                         = "opencode"
  resource_group_name          = azurerm_resource_group.rg.name
  container_app_environment_id = local.environment_id
  revision_mode                = "Single"
  workload_profile_name        = "Consumption"

  depends_on = [
    azurerm_role_assignment.acr_pull,
    azurerm_role_assignment.opencode_config_reader,
    azurerm_role_assignment.opencode_sessions_contributor,
    azurerm_container_app_environment_storage.workspace,
  ]

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
    min_replicas = 0
    max_replicas = 1

    container {
      name   = "opencode"
      image  = "${azurerm_container_registry.acr.login_server}/opencode:${var.image_tag}"
      cpu    = 0.5
      memory = "1Gi"

      env {
        name        = "AZURE_API_KEY"
        secret_name = "azure-key"
      }
      env {
        name  = "AZURE_RESOURCE_NAME"
        value = var.foundry_resource
      }
      env {
        name        = "GITHUB_TOKEN"
        secret_name = "gh-token"
      }
      env {
        name  = "AZURE_CLIENT_ID"
        value = azurerm_user_assigned_identity.app.client_id
      }
      env {
        name  = "OPENCODE_STORAGE_ACCOUNT"
        value = azurerm_storage_account.sa.name
      }
      env {
        name  = "OPENCODE_CONFIG_CONTAINER"
        value = azurerm_storage_container.opencode_config.name
      }
      env {
        name  = "OPENCODE_SESSION_CONTAINER"
        value = azurerm_storage_container.opencode_sessions.name
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