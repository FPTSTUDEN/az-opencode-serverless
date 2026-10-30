# OpenCode on Azure Container Apps

## Deployment notes

- By default, the app creates a dedicated Container Apps environment in the configured region.
- If the subscription allows only one environment, set `environment_mode = "shared"` in `terraform.tfvars` and configure the existing environment name and resource group. This uses `azure-xiaoxi-siyuan-env` in `rg-siyuan-prod` by default.
- Azure Files storage is not supported by ACA Express environments. The shared environment must be a standard/workload-profile environment with a delegated infrastructure subnet.
- Container Apps environments and other Azure resources are regional. Changing `location` does not move them; it can force replacement and should be treated as a migration.
- `deploy.ps1` is the first-time/full deployment command. It bootstraps the resource group and ACR, builds a content-derived immutable image tag, applies Terraform, publishes the current OpenCode config, and restarts the latest revision.
- `build-image.ps1` builds a content-derived immutable image tag from the Dockerfile and runtime code, then writes the selected tag to the ignored `image.auto.tfvars.json`. OpenCode is pinned in the image; `opencode.json` is deliberately excluded because config-only changes are published separately.
- Keep non-secret OpenCode settings in the tracked `opencode.json`. After `az login`, run `.\publish-config.ps1 -Restart` to check JSON syntax and publish a SHA-256-versioned artifact and update the `current.json` pointer in the private Blob container. Terraform grants the identity running `terraform apply` `Storage Blob Data Contributor` only on the config container, so the same signed-in operator can publish with `az login`. Roll back by publishing the desired config file again; no image build or Terraform update is required.
- The `gh_pat` Terraform variable is provided to GitHub CLI as `GITHUB_TOKEN`; the container runs `gh auth setup-git` at startup so Git can clone private repositories over HTTPS. SSH-style GitHub clone URLs are rewritten to HTTPS. Give the PAT read access to the target repository's contents (and authorize it for organization SSO when required); the token is not written into clone URLs or Git configuration.
- The `workspace` Azure Files share is mounted with `mfsymlinks` to enable Linux SMB symlink emulation for project dependency installs. OpenCode's live SQLite database and XDG data directory use replica-local storage, not SMB. Before attempting each Blob upload, the app atomically stages the latest per-session JSON snapshot at `/workspace/.opencode-exports/<session-id>.json`; on the share, this is `.opencode-exports/<session-id>.json`. This includes snapshots skipped as ambiguous conflicts. On restart, a staged snapshot that is newer than or conflicts with Blob is preferred, promoted to Blob with an ETag condition, and imported before OpenCode starts; an older staged snapshot is ignored. These files contain conversation content and are readable by anyone with workspace-share access. Each file is a complete CLI export document but can capture an unfinished turn; the latest snapshot overwrites that session's prior staged file. The `opencode-sessions` private Blob container stores exports; startup imports snapshots before OpenCode starts, and the app targets exports about once a minute plus a best-effort shutdown export. Runtime logs include structured per-cycle session ID lists, each session's export/stage/Blob outcome, and startup restore source/import outcome. IDs are repeated in logs; titles and transcript content are not logged. Changes since the last completed export can still be lost if the replica stops abruptly.
- On first startup, if `/workspace/.opencode-data/opencode/opencode.db` exists and no migration marker is present, the app exports those legacy sessions to Blob before starting. If legacy export fails, startup fails closed rather than silently starting without the conversations. This one-time read of the legacy SQLite database on Azure Files can still encounter SMB/SQLite locking; verify migration and preserve the old share until the restored sessions are confirmed.
- Terraform creates private config/session Blob containers, grants the app identity config-reader and session-contributor roles, enables Blob versioning, and retains noncurrent session versions for 30 days (with 7-day soft-delete retention). Config content and conversation exports are not stored in Terraform state or copied into the image. The operator who publishes config needs Blob Data Contributor on the config container.
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
