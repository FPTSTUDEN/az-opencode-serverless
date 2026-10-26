# OpenCode on Azure Container Apps

## Deployment notes

- By default, the app creates a dedicated Container Apps environment in the configured region.
- If the subscription allows only one environment, set `environment_mode = "shared"` in `terraform.tfvars` and configure the existing environment name and resource group. This uses `azure-xiaoxi-siyuan-env` in `rg-siyuan-prod` by default.
- Azure Files storage is not supported by ACA Express environments. The shared environment must be a standard/workload-profile environment with a delegated infrastructure subnet.
- Container Apps environments and other Azure resources are regional. Changing `location` does not move them; it can force replacement and should be treated as a migration.
- `build-image.ps1` builds `opencode:latest` separately in ACR. Build the image before applying Terraform when the Container App does not already exist.
- Terraform state can become stale after a partial apply. If Azure reports a resource as existing but Terraform plans to create it, verify the resource with Azure CLI and import it rather than creating a duplicate.
- A transient Azure `404` during provisioning can cause a refresh to remove a resource from Terraform state. Avoid repeated applies or refreshes while Azure operations are still settling; inspect the actual Azure resource and state first.
- If the AzureRM provider reports `Provider produced inconsistent result after apply`, verify the resource exists, then import it and clear a taint only after confirming it is healthy.

Useful commands:

```powershell
terraform plan
terraform state list
az resource list --resource-group <resource-group>
terraform import <terraform-address> <azure-resource-id>
.\build-image.ps1 -RegistryName <acr-name>
```
