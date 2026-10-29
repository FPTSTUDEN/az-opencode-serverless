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

resource "azurerm_storage_share" "conversation_data" {
  name               = "opencode-conversations"
  storage_account_id = azurerm_storage_account.sa.id
  quota              = 50
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

resource "azurerm_container_app_environment_storage" "conversation_data" {
  name                         = "opencode-conversations"
  container_app_environment_id = local.environment_id
  account_name                 = azurerm_storage_account.sa.name
  share_name                   = azurerm_storage_share.conversation_data.name
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
  container_app_environment_id = local.environment_id
  revision_mode                = "Single"
  workload_profile_name        = "Consumption"

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

resource "azurerm_storage_share_directory" "smb_test" {
  name              = ".opencode-smb-test"
  storage_share_url = azurerm_storage_share.workspace.url
}

resource "azurerm_storage_share_directory" "smb_test_data" {
  name              = ".opencode-smb-test-data"
  storage_share_url = azurerm_storage_share.workspace.url
}

resource "azurerm_container_app" "opencode_smb_test" {
  name                         = "opencode-smb-test"
  resource_group_name          = azurerm_resource_group.rg.name
  container_app_environment_id = local.environment_id
  revision_mode                = "Single"
  workload_profile_name        = "Consumption"

  depends_on = [
    azurerm_role_assignment.acr_pull,
    azurerm_container_app_environment_storage.workspace,
    azurerm_container_app_environment_storage.conversation_data,
    azurerm_storage_share_directory.smb_test,
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
      image  = "${azurerm_container_registry.acr.login_server}/opencode:${coalesce(var.smb_test_image_tag, var.image_tag)}"
      cpu    = 1
      memory = "2Gi"

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
        name        = "OPENCODE_SERVER_PASSWORD"
        secret_name = "ui-pass"
      }
      env {
        name  = "XDG_DATA_HOME"
        value = "/opencode-data"
      }

      command = ["/bin/sh", "-c"]
      args = [<<-SHELL
        probe="$(mktemp -d /workspace/.smb-probe.XXXXXX)" || exit 1
        mkdir "$probe/package" "$probe/bin" || exit 1
        printf '{"name":"smb-probe"}' > "$probe/package/package.json" || exit 1
        ln -s ../package/package.json "$probe/bin/test-cli" || exit 1
        test -L "$probe/bin/test-cli" || exit 1
        test "$(cat "$probe/bin/test-cli")" = '{"name":"smb-probe"}' || exit 1
        mv "$probe/package" "$probe/package-renamed" || exit 1
        test -L "$probe/bin/test-cli" || exit 1
        test -f "$probe/package-renamed/package.json" || exit 1
        rm -rf "$probe" || exit 1
        printf 'SMB_SYMLINK_RENAME_PROBE_PASS\n'
        mkdir -p "$XDG_DATA_HOME" || exit 1
        printf 'smb-data-probe' > "$XDG_DATA_HOME/.mount-probe" || exit 1
        test "$(cat "$XDG_DATA_HOME/.mount-probe")" = 'smb-data-probe' || exit 1
        rm "$XDG_DATA_HOME/.mount-probe" || exit 1
        printf 'SMB_DATA_MOUNT_PROBE_PASS\n'
        exec /usr/local/bin/start-opencode opencode web --hostname 0.0.0.0 --port 4096
        SHELL
      ]

      volume_mounts {
        name     = "workspace"
        path     = "/workspace"
        sub_path = azurerm_storage_share_directory.smb_test.name
      }

      volume_mounts {
        name = "opencode-data"
        path = "/opencode-data"
      }
    }

    volume {
      name          = "workspace"
      storage_name  = azurerm_container_app_environment_storage.workspace.name
      storage_type  = "AzureFile"
      mount_options = "mfsymlinks"
    }

    volume {
      name         = "opencode-data"
      storage_name = azurerm_container_app_environment_storage.conversation_data.name
      storage_type = "AzureFile"
    }
  }
}