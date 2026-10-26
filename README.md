# OpenCode on Azure Container Apps

## Deployment notes

- By default, the app creates a dedicated Container Apps environment in the configured region.
- If the subscription allows only one environment, set `environment_mode = "shared"` in `terraform.tfvars` and configure the existing environment name and resource group. This uses `azure-xiaoxi-siyuan-env` in `rg-siyuan-prod` by default.
- Azure Files storage is not supported by ACA Express environments. The shared environment must be a standard/workload-profile environment with a delegated infrastructure subnet.
- Container Apps environments and other Azure resources are regional. Changing `location` does not move them; it can force replacement and should be treated as a migration.
- `deploy.ps1` is the first-time/full deployment command. It bootstraps the resource group and ACR, builds a content-derived immutable image tag, then applies the remaining Terraform resources.
- `build-image.ps1` builds a content-derived immutable image tag separately in ACR and writes the selected tag to the ignored `image.auto.tfvars.json`. Use it before `terraform apply` for later image/config changes; avoid manually reverting `image_tag` to `latest`.
- The `gh_pat` Terraform variable is provided to GitHub CLI as `GITHUB_TOKEN`; the container runs `gh auth setup-git` at startup so Git can clone private repositories over HTTPS. SSH-style GitHub clone URLs are rewritten to HTTPS. Give the PAT read access to the target repository's contents (and authorize it for organization SSO when required); the token is not written into clone URLs or Git configuration.
- The `workspace` Azure Files share stores cloned project files and the `.opencode-data` directory. At startup, `XDG_DATA_HOME` points OpenCode to that directory so conversations and application data persist across image revisions without requiring a second file share.
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
