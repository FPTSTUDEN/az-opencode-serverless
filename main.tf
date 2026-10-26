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

resource "azurerm_log_analytics_workspace" "law" {
  name                = "${local.name}-law"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  sku                 = "PerGB2018"
  retention_in_days   = 30
}

resource "azurerm_container_app_environment" "env" {
  name                       = "${local.name}-env"
  resource_group_name        = azurerm_resource_group.rg.name
  location                   = azurerm_resource_group.rg.location
  log_analytics_workspace_id = azurerm_log_analytics_workspace.law.id
}

resource "azurerm_container_app_environment_storage" "workspace" {
  name                         = "workspace"
  container_app_environment_id = azurerm_container_app_environment.env.id
  account_name                 = azurerm_storage_account.sa.name
  share_name                   = azurerm_storage_share.workspace.name
  access_key                   = azurerm_storage_account.sa.primary_access_key
  access_mode                  = "ReadWrite"
}

# Build the image in ACR (no local Docker needed).
# Re-run `terraform apply -replace=null_resource.image_build` after changing Dockerfile or opencode.json.
resource "null_resource" "image_build" {
  triggers = {
    dockerfile = filesha256("${path.module}/Dockerfile")
    config     = filesha256("${path.module}/opencode.json")
  }
  provisioner "local-exec" {
    command = "az acr build -r ${azurerm_container_registry.acr.name} -t opencode:latest --no-logs ${path.module}"
    environment = {
      PYTHONIOENCODING = "utf-8"
    }
  }
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
  container_app_environment_id = azurerm_container_app_environment.env.id
  revision_mode                = "Single"

  depends_on = [null_resource.image_build, azurerm_role_assignment.acr_pull]

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