# Deployment Plan

## Proposed Dedicated Conversation-Share Retest

### Status
Revision `opencode-smb-test--0000012` deployed the XDG environment-variable fix and uses the dedicated `opencode-conversations` share at `/opencode-data` (root, no subpath or `mfsymlinks`). Both SMB probes pass, but OpenCode exits with `database is locked`; the startup probe then fails. The share now contains `opencode/opencode.db` at 0 bytes plus `log` and `repos` directories. Azure reports revision `0000012` with 0 replicas and 100% traffic; prior revision `0000011` still has 1 replica but 0% traffic. Production revision `0000006` also reports `database is locked`; production revisions `0000003` (0% traffic) and `0000006` (100% traffic) each currently have 1 replica and both mount the same `workspace` share at `/workspace`, so concurrent SQLite access is a possible contributor there. The production share's current `opencode.db` also reports 0 bytes. This does not prove historical revision `0000003` behavior, and the test error still occurs on its separate share. Production is unchanged.

### Proposed changes
- Keep the test workspace on the existing `workspace` share, isolated under `.opencode-smb-test` at `/workspace` with `mfsymlinks`.
- Keep the conversation share root mounted at `/opencode-data` without mount options and set `XDG_DATA_HOME=/opencode-data` as a Container Apps environment variable.
- Preserve the conversation DB and WAL files still held by revision `0000011` at the CR-suffixed local path before deactivating or restarting that replica. Do not treat the new zero-byte database as a migrated copy.
- Investigate a persistence backend with locking semantics suitable for SQLite or a supported server database before further SMB SQLite retries.

### Risks
- The CR-suffixed database is outside Azure Files and can be lost when its container stops. SQLite on the new Azure Files share is currently failing at startup; production remains unchanged.

## Proposed Non-Nested SMB Data-Mount Test

### Status
Deployed and verified on 2026-10-29. Revision `opencode-smb-test--0000009` is healthy with one ready replica using `.opencode-smb-test-data` at `/tmp/opencode-data`; both SMB probes pass and the endpoint returns expected HTTP 401 without credentials. Production is unchanged. Conversation DB persistence across a user-created conversation/restart remains to be confirmed.

### Proposed changes
- Keep the current test-only image (`opencode:5bf592919948`) and its `start-opencode` invocation.
- Moved only the `.opencode-smb-test-data` mount from `/workspace/.opencode-smb-test-data` to `/tmp/opencode-data`, and set `XDG_DATA_HOME=/tmp/opencode-data`; no `OPENCODE_DB` override.
- Keep project files mounted at `/workspace` from `.opencode-smb-test`.
- Deactivated old test revision `opencode-smb-test--0000004` before launching the new revision to prevent concurrent access to the data directory.
- Deployed only the isolated test app; no data was deleted or overwritten, and production remains untouched.

### Risks
- The test URL may be briefly unavailable while the old revision is deactivated and the new one starts.
- SQLite can still fail with `database is locked` even with a non-nested mount; the existing data directory may contain files from prior attempts.

## Proposed Test-Only Startup-Script Alignment

### Status
Applied on 2026-10-28. A test-only image was built and revision `opencode-smb-test--0000008` invokes the updated `start-opencode` script with `XDG_DATA_HOME=/workspace/.opencode-smb-test-data`. Startup probes pass, but OpenCode still exits with `database is locked`. Prior revision `0000004` remains active and healthy; production is unchanged.

### Proposed changes
- Make `start-opencode` honor a caller-provided `XDG_DATA_HOME`, while retaining `/workspace/.opencode-data` as its default so the production/default behavior is unchanged.
- Change only the test app startup to set `XDG_DATA_HOME=/workspace/.opencode-smb-test-data` and invoke `/usr/local/bin/start-opencode opencode web ...`, matching the previously working entrypoint flow; remove the explicit `OPENCODE_DB` override.
- Keep the isolated Azure Files subpath `.opencode-smb-test-data` mounted at `/workspace/.opencode-smb-test-data`.
- Build a test-only ACR image with `build-image.ps1 -ForSmbTest`; retain production's current image tag.
- Validate Terraform and review a saved plan; deploy only the test app and confirm startup/readiness/logs. Do not alter production or delete persisted data.

### Risks
- SQLite on Azure Files SMB can still fail with `database is locked`; this test will isolate the startup-script difference but cannot guarantee SMB locking compatibility.
- Building the test-only image consumes ACR build resources. The existing test endpoint may remain unavailable until its image/config is fixed.

## Proposed SMB Conversation Data-Path Retest

### Status
Revision `opencode-smb-test--0000007` uses the requested mount path but crash-loops on `database is locked`, including after the previously healthy revision `0000004` was deactivated with user approval. This points to Azure Files SMB SQLite behavior or another lock in the mounted data path, not just cross-revision overlap. The test endpoint may currently be unavailable; production is untouched. Awaiting user direction on rollback versus further storage investigation.

### Finding
The test app sets `XDG_DATA_HOME=/tmp/opencode-data` and mounts a dedicated SMB directory at that path, but conversation persistence failed. OpenCode derives its global data directory as `$XDG_DATA_HOME/opencode`; its database path can also be explicitly controlled through `OPENCODE_DB`. The existing `start-opencode` script uses `XDG_DATA_HOME=/workspace/.opencode-data`, but the test app overrides the image entrypoint and does not run that script.

### Proposed changes
- Keep production unchanged and retain the test app's 1 vCPU / 2 GiB sizing and current provider-enabled image.
- Mount the existing `.opencode-smb-test-data` Azure Files subpath at `/workspace/.opencode-smb-test-data` and set `XDG_DATA_HOME` to that exact path, as requested.
- Explicitly set `OPENCODE_DB=/workspace/.opencode-smb-test-data/opencode.db` so the conversation SQLite database lands at the root of the mounted data directory, not an implicit nested location.
- Log the explicit `OPENCODE_DB` path at startup (do not invoke the DB-inspecting CLI during startup because it hit a lock) and retain a non-destructive mount read/write probe; do not delete or overwrite any existing data.
- Validate Terraform, confirm the plan updates only the isolated test app with zero destroys, deploy, then test a new conversation and verify the database file appears and survives a revision restart.

### Risks
- SMB-hosted SQLite may still have locking/corruption behavior even when the mount target is correct; this remains experimental.
- Do not remove, rename, or overwrite any existing test data while correcting the mount.

## Proposed Test-App Provider Image Refresh

### Status
Deployed and verified on 2026-10-28. ACR build `dt9` produced `opencode:d23271c1012d`; test revision `opencode-smb-test--0000004` is healthy. Production remains on `opencode:799e9c2cc141`. The test image includes the current `opencode.json` default model/provider configuration; user confirmation of model visibility in the UI is still pending.

### Finding
The repository has an OpenCode default model/provider in `opencode.json`, and the Dockerfile copies that file into the image. The test app currently runs `opencode:799e9c2cc141`, while the current source-derived image tag is `opencode:d23271c1012d`. Terraform currently shares `image_tag` between production and the test app, so changing it directly would also roll production.

### Proposed changes
- Build the current image into ACR using the content-derived tag.
- Add a separate optional `smb_test_image_tag` for only `opencode-smb-test`, falling back to the shared `image_tag` when unset.
- Add a `build-image.ps1` test-app mode that writes a separate ignored Terraform auto-vars file for `smb_test_image_tag`, leaving production's selected tag unchanged.
- Apply the test-app image change only; do not update the production app, model deployment, secrets, or provider config.
- Verify the new revision loads the preconfigured `azure/gpt-5` model and returns to healthy status.

### Risks
- The current model entry is already defined in source; this test isolates whether the stale container image explains the missing provider UI state.
- The ACR build consumes build resources; no new Azure infrastructure is planned.

## Proposed SMB Conversation-State Test

### Status
Deployed and verified on 2026-10-28. User approved this isolated test-app change; the latest revision is healthy, the SMB data-mount probe passed, and the endpoint responds with expected HTTP 401 without credentials. Focused Terraform checks passed; the repository-wide validator wrapper has a known PowerShell argument-forwarding issue, and pre-existing `.tfvars` formatting is outside this change.

### Goal
Retest the isolated `opencode-smb-test` app with 2 GiB RAM and persistent OpenCode conversation data on a separate Azure Files SMB subdirectory, while retaining the existing `.opencode-smb-test` project workspace mount.

### Proposed changes
- Increase the test container from 0.5 vCPU / 1 GiB to 1 vCPU / 2 GiB (the supported Consumption resource pair for 2 GiB).
- Create a distinct share directory `.opencode-smb-test-data` and mount it at `/tmp/opencode-data` with `mfsymlinks`.
- Keep `XDG_DATA_HOME=/tmp/opencode-data`, so OpenCode conversation state uses that mount; leave the project mount at `/workspace` backed by `.opencode-smb-test`.
- Do not modify the production app or other mounts/resources.

### Validation and deployment
- Review Terraform plan to confirm only the new data directory and isolated test-app update are proposed, with no production changes or destroys.
- Run `terraform fmt`, `terraform validate`, and `terraform plan`.
- After approval and validation, deploy through the Azure deployment workflow; verify the new revision is ready and its data path is mounted.
- Ask the user to test conversation persistence across a test-app restart and package installation, then review ACA restart/memory diagnostics.

### Risks
- SMB-backed SQLite conversation state may still encounter locking or latency issues; this is an experiment, not a production recommendation.
- 1 vCPU / 2 GiB increases active test compute usage compared with the current test allocation.
- State remains confined to the dedicated test data directory; production data is out of scope.

## SMB Symlink Test Deployment

### Status
Deployed and verified. The isolated test app is running with `mfsymlinks`; its startup symlink/rename probe passed. Production app configuration was not changed.

### Validation evidence
- `terraform init -input=false` — PASS.
- `terraform fmt -check main.tf outputs.tf` — PASS.
- `terraform validate` — PASS.
- Full `terraform plan -input=false -no-color` — PASS; updates only the isolated test app, with 0 adds and 0 destroys.
- `terraform state list` — PASS.
- Template variable scan — PASS in the prescribed preflight script.
- `main.tfvars.json` syntax check — SKIP; file absent.
- Azure CLI confirms existing environment storage registration; production app configuration was read only.
- Microsoft.App quota query returned no quota rows; this is an existing Consumption environment with max 1 test replica.
- Initial test revision hit `database is locked` when OpenCode state was on SMB, so the prior revision kept XDG data local/ephemeral. The current revision deliberately mounts a distinct share directory at `/tmp/opencode-data` to retest state persistence and SQLite behavior after increasing memory.
- Runtime logs confirm `SMB_SYMLINK_RENAME_PROBE_PASS`; unauthenticated endpoint probe returned HTTP 401 as expected for the password-protected server.
- Live app state: `opencode-smb-test--0000002`, provisioning `Succeeded`, 1 active replica, URL `https://opencode-smb-test.agreeablesea-cc7fbc1c.swedencentral.azurecontainerapps.io`.
- Azure validation wrapper failures: the PowerShell helper passes no Terraform arguments because its `Args` parameter shadows PowerShell's automatic `$Args`; equivalent Terraform checks were run directly and pass.
- `terraform fmt -check -recursive` reports pre-existing formatting in `terraform.tfvars` and `terraform copy.tfvars`. These unrelated files were not changed; modified `.tf` files pass targeted formatting check.

## Section 7: Validation Proof
- 2026-10-29 09:21 +07 — Terraform apply completed: test app only, 0 added, 1 changed, 0 destroyed.
- 2026-10-29 09:21 +07 — Revision `opencode-smb-test--0000009` healthy, 1 ready replica, 0 restarts; mount is `.opencode-smb-test-data` at `/tmp/opencode-data`; logs show both SMB probes passed; endpoint returned HTTP 401 without credentials.
- 2026-10-29 09:21 +07 — Earlier healthy revision `0000004` has no running replica and receives 0 traffic, avoiding concurrent active processes.
- 2026-10-28 23:08 +07 — `terraform fmt -check main.tf variables.tf outputs.tf`, `terraform validate`, and `bash -n start-opencode`: PASS.
- 2026-10-28 23:08 +07 — `terraform plan -input=false -no-color`: PASS; only test app mount/XDG path changes from nested `/workspace/.opencode-smb-test-data` to `/tmp/opencode-data`, 0 add, 1 change, 0 destroy.
- 2026-10-28 23:08 +07 — Terraform state list, Azure subscription, existing ACR `AcrPull`, and template-variable scan: PASS.
- 2026-10-28 22:30 +07 — ACR build `dta` succeeded with `opencode:5bf592919948` (digest `sha256:bdfc38c130084f546e94e9626561ec42362c8beaf0cead039a40f009afc974a3`).
- 2026-10-28 22:30 +07 — Terraform plan/apply updated only `opencode-smb-test` to the test-only image and startup script (0 add, 1 change, 0 destroy).
- 2026-10-28 22:30 +07 — Revision `opencode-smb-test--0000008` ran both SMB probes but OpenCode still exited with `database is locked`; revision `0000004` remains active/healthy. Production image unchanged.
- 2026-10-28 22:13 +07 — `terraform fmt -check main.tf variables.tf outputs.tf`, `terraform validate`, and `bash -n start-opencode`: PASS.
- 2026-10-28 22:13 +07 — `terraform plan -input=false -no-color`: PASS; only the isolated test app startup changes, 0 add, 1 change, 0 destroy. The current test image tag still needs a test-only rebuild because it bakes in `start-opencode`.
- 2026-10-28 22:13 +07 — Terraform state list, Azure subscription, existing ACR `AcrPull`, and template-variable scan: PASS.
- 2026-10-28 21:54 +07 — `terraform fmt -check main.tf variables.tf outputs.tf` and `terraform validate`: PASS.
- 2026-10-28 21:54 +07 — `terraform plan -input=false -no-color`: PASS; only `opencode-smb-test` mount/environment path changed to `/workspace/.opencode-smb-test-data`, 0 add, 1 change, 0 destroy.
- 2026-10-28 21:54 +07 — Terraform state list, Azure CLI subscription, and existing ACR `AcrPull` role verified.
- Previous revision `0000006` had passed the SMB mount probe but crashed on `database is locked` after launching OpenCode; this revision tests the user-requested mount path. The `opencode db path` CLI diagnostic was removed; startup only prints the configured DB path.
- 2026-10-28 21:35 +07 — `terraform fmt -check main.tf variables.tf outputs.tf` and `terraform validate`: PASS.
- 2026-10-28 21:35 +07 — `terraform plan -input=false -no-color`: PASS; one in-place test-app startup diagnostic update, 0 add, 1 change, 0 destroy.
- The previous apply attempt generated revision `opencode-smb-test--0000005`, which crash-looped because the startup diagnostic command `opencode db path` returned `database is locked`; revision `0000004` remained healthy. The retry removes that DB-opening diagnostic, logs the configured `OPENCODE_DB` path only, and starts the server.
- 2026-10-28 21:23 +07 — `terraform init -input=false`, `terraform fmt -check main.tf variables.tf outputs.tf`, and `terraform validate`: PASS.
- 2026-10-28 21:23 +07 — `terraform plan -input=false -no-color`: PASS; only in-place `opencode-smb-test` startup/mount-path update, 0 add, 1 change, 0 destroy.
- 2026-10-28 21:23 +07 — `terraform state list`, unresolved-template scan: PASS; `main.tfvars.json` absent (skipped); Azure CLI subscription `Azure for Students` and existing `AcrPull` verified.
- 2026-10-28 21:06 +07 — ACR build `dt9` succeeded with image `opencode:d23271c1012d` (digest `sha256:a7d89d36f5708694199271c895f8f0d5c8e684e2e218bc9659c855b92dba33d9`).
- 2026-10-28 21:06 +07 — Terraform plan showed only the isolated test app image change (0 add, 1 change, 0 destroy); apply completed (0 add, 1 change, 0 destroy).
- 2026-10-28 21:06 +07 — Revision `opencode-smb-test--0000004` is healthy with 1 replica. Test app uses 1 vCPU / 2 GiB and image `opencode:d23271c1012d`; production remains on `opencode:799e9c2cc141`.
- 2026-10-28 21:06 +07 — Startup logs show `SMB_SYMLINK_RENAME_PROBE_PASS` and `SMB_DATA_MOUNT_PROBE_PASS`; endpoint responds HTTP 401 without credentials as expected.
- 2026-10-28 20:55 +07 — `terraform init -input=false`: PASS.
- 2026-10-28 20:55 +07 — `terraform fmt -check main.tf variables.tf outputs.tf`, `terraform validate`, and `build-image.ps1` parser check: PASS.
- 2026-10-28 20:55 +07 — `terraform plan -input=false -no-color`: PASS; only updates `opencode-smb-test` image from `799e9c2cc141` to source-derived `d23271c1012d`, 0 adds, 1 change, 0 destroys; production unchanged.
- 2026-10-28 20:55 +07 — `terraform state list` and Go-style template scan: PASS; `main.tfvars.json` absent (skipped).
- The official preflight wrapper was attempted but PowerShell's `Args` parameter-shadowing bug caused Terraform commands to print usage; equivalent checks above passed directly.
- 2026-10-28 20:28 +07 — `terraform init -input=false`: PASS.
- 2026-10-28 20:28 +07 — `terraform fmt -check main.tf outputs.tf`: PASS.
- 2026-10-28 20:28 +07 — `terraform validate`: PASS.
- 2026-10-28 20:28 +07 — `terraform plan -input=false -no-color`: PASS; only creates `.opencode-smb-test-data` and updates `opencode-smb-test` to 1 vCPU/2 GiB with a second SMB mount; 1 add, 1 change, 0 destroy.
- 2026-10-28 20:28 +07 — `terraform state list`, template-variable scan: PASS; `main.tfvars.json` absent (JSON check skipped).
- 2026-10-28 20:28 +07 — Azure CLI authenticated and selected subscription `4251edde-d9a9-4e8c-8855-79399bd4dc45`: PASS.
- The official preflight wrapper was attempted but its `Args` parameter-shadowing bug caused Terraform commands to print usage; equivalent checks were then run directly. The wrapper run is not counted as proof of Terraform validation.
- 2026-10-28 20:34 +07 — `terraform apply` completed: 1 share directory added, isolated test app updated, 0 destroys.
- 2026-10-28 20:34 +07 — Azure reports revision `opencode-smb-test--0000003` healthy with 1 replica; configured resources are 1 vCPU / 2 GiB, and mounts are `.opencode-smb-test` at `/workspace` and `.opencode-smb-test-data` at `/tmp/opencode-data`, both with `mfsymlinks`.
- 2026-10-28 20:34 +07 — Runtime logs show `SMB_SYMLINK_RENAME_PROBE_PASS` and `SMB_DATA_MOUNT_PROBE_PASS`; endpoint returns expected HTTP 401 without credentials.
- 2026-10-28 18:39 +07 — `terraform fmt -check main.tf outputs.tf`: PASS.
- 2026-10-28 18:39 +07 — `terraform validate`: PASS.
- 2026-10-28 18:39 +07 — `terraform plan -input=false -no-color`: PASS; updates only the test app's startup command, 0 add / 1 change / 0 destroy.
- 2026-10-28 18:47 +07 — repeat `terraform fmt -check main.tf outputs.tf`, `terraform validate`, `terraform plan -input=false -no-color`: PASS; same test-app-only update.
- 2026-10-28 18:33 +07 — `terraform state list`: PASS.
- 2026-10-28 18:35 +07 — `az role assignment list` for the existing app identity and ACR: `AcrPull` present.
- The existing workspace probe checks symlink create/read and directory rename; the proposed test additionally probes read/write in the separate SMB-backed OpenCode data mount. Production app/storage are unchanged.
- Preflight workflow helper failed to forward Terraform CLI args due to `Args` parameter shadowing; equivalent direct commands above passed.
- Recursive formatting still flags pre-existing `terraform.tfvars` and `terraform copy.tfvars`; touched `.tf` files pass formatting and unrelated tfvars remain unchanged.
- No application source or image changes; build step not applicable.
- 2026-10-28 18:50 +07 — Terraform apply created the dedicated share directory and isolated test app (2 added, 0 changed, 0 destroyed).
- 2026-10-28 18:53 +07 — Terraform apply updated only the test app after the first startup attempt (0 added, 1 changed, 0 destroyed).
- 2026-10-28 18:54 +07 — Container Apps diagnostics report `SMB_SYMLINK_RENAME_PROBE_PASS` and OpenCode listening; endpoint probe returns HTTP 401 without credentials.

## All validation checks pass
- [x] Terraform installed.
- [x] Azure CLI installed and authenticated to the confirmed subscription.
- [x] Terraform initialized successfully.
- [x] Targeted Terraform formatting check for modified `.tf` files; recursive formatting check is not included because existing unrelated `.tfvars` files are known to be unformatted.
- [x] Terraform configuration validation.
- [x] Confirm plan changes only `opencode-smb-test` mount/startup settings, with no destroys.
- [x] Verify no existing data is deleted or overwritten by startup probes.
- [x] Current A/B startup config mounts `.opencode-smb-test-data` at non-nested `/tmp/opencode-data`, matching healthy revision `0000004`.
- [x] `start-opencode` preserves `/workspace/.opencode-data` as its default and honors an explicit test `XDG_DATA_HOME` override.
- [x] Test container invokes the image's `start-opencode` script after the filesystem probes.
- [x] PowerShell parser check for `build-image.ps1`.
- [x] Terraform plan reviewed: isolated test-app update and new data directory only; zero destroys.
- [x] Terraform state list and template-variable scan.
- [x] `main.tfvars.json` absent; JSON syntax check skipped.
- [x] Terraform installed and Azure CLI authenticated to the approved subscription.
- [x] Terraform init, format check, validate, and plan.
- [x] Full plan contains only the isolated test app update; no production changes or destroys.
- [x] Terraform state list and template variable scan.
- [x] JSON syntax check (skipped: `main.tfvars.json` is not present).
- [x] Container image, ACR pull identity, secret names, mount source, and ingress match existing app settings without displaying secret values.
- [x] Static RBAC review confirms reuse of the existing managed identity and ACR pull assignment; no new role assignment.

## Role Assignment Verification
- Status: Verified (static review).
- Identities checked: Existing user-assigned Container App identity `app`, reused by the test app.
- Role confirmed: `AcrPull` scoped to the app's Azure Container Registry.
- No additional role assignment is required for the SMB file share key-based mount.
- [x] Apply the isolated test deployment only after validation workflow completes.
- [x] Verify startup, app readiness, and SMB filesystem behavior in the dedicated subdirectory.

### Goal
Validate whether enabling Minshall+French symlink support on the ACA SMB mount resolves dependency installation failures, without modifying the existing OpenCode app or its workspace contents.

### Approved scope
- Reuse existing Container Apps environment, immutable OpenCode image, Azure Files SMB share registration, and required auth configuration.
- Create a separately named test Container App, mounting only a dedicated test subdirectory of the existing share at `/workspace` with `mfsymlinks`.
- Keep min replicas at 0 and max replicas at 1.
- Do not change or restart the existing application.
- Validate app readiness, symlink create/read/delete, and npm/pnpm-style rename/delete behavior in the isolated directory before inviting user testing.
- No new storage account/share or NFS resources in this test.

### Confirmed context
- Subscription: Azure for Students (4251edde-d9a9-4e8c-8855-79399bd4dc45).
- Region: Sweden Central.
- Existing environment: azure-xiaoxi-siyuan-env in rg-siyuan-prod; Consumption profile and custom infrastructure subnet confirmed by read-only Azure queries.
- Existing immutable app image: oh77b363acr.azurecr.io/opencode:799e9c2cc141.
- Existing production app and workspace remain out of scope for edits.
- User approved separate SMB mount-options test on 2026-10-28.

### Risks and safeguards
- Before deployment, verify ACA and Terraform/provider support for the `mfsymlinks` mount option and subdirectory mounts. Do not silently deploy without it.
- Verify SMB server path confinement and mount only a dedicated directory, not production workspace content.
- Reuse secrets without printing them or writing values to tracked files.
- If mount option/subdirectory isolation is unsupported, stop and request an alternative rather than mount the production share root.
- No new Azure Files capacity cost anticipated; test app incurs compute while active, plus routine logging.

### Validation
- Terraform plan should show only additive isolated test resources; do not apply changes to the current app.
- After deployment, verify endpoint responds; test filesystem operations only within the isolated test directory; report the test URL and cleanup instructions.
- The user will test OpenCode/npm in the isolated instance.

## Previous Compute Change

## Status
Validation incomplete — the requested `main.tf` checks passed, but recursive formatting reports pre-existing formatting in two `.tfvars` files. No deployment performed.

## Mode
MODIFY — adjust compute settings for the existing OpenCode Azure Container App.

## Goal
Reduce Container Apps compute costs by scaling the app to zero when idle and testing a smaller container allocation.

## Existing architecture (before this change)
- OpenCode runs in Azure Container Apps on a Consumption workload profile.
- Terraform manages the app in `main.tf`.
- External ingress is enabled on port 4096.
- The app had one minimum and maximum replica, with 1 vCPU and 2 GiB memory.
- Azure Files is mounted read/write at `/workspace`; application secrets and registry identity are out of scope.

## Requirements
- Cost-optimized change, based on observed active and idle compute charges.
- Preserve public access, persistent workspace storage, secrets, image, and existing maximum replica count.
- No deployment or `terraform apply` as part of this change.
- Classification, user scale, compliance constraints, subscription, and deployment location have not been confirmed; no Azure resources will be provisioned or changed by this task.

## Proposed changes
- Set `min_replicas = 0`; retain `max_replicas = 1` so the app can scale to zero while preserving the current cap.
- Reduce container requests from 1 vCPU / 2 GiB to 0.5 vCPU / 1 GiB for a measured test.
- Modify only the existing Container App resource in `main.tf`.

## Recipe
Terraform, continuing the project's existing Terraform workflow. No AZD conversion.

## Risks and validation
- Scale-to-zero introduces cold starts and may delay the first request after idle.
- Smaller resources may slow OpenCode or browser workloads or cause out-of-memory restarts.
- After approval, run Terraform formatting and validation, then inspect a plan; do not apply it.
- User should monitor latency, replica restarts, and compute charges before deciding whether to keep the smaller size.

## Policy Constraints
No policy query performed; the task does not provision resources. Azure CLI authentication and read-only Terraform data lookups were used for validation.

## Build Verification
Not applicable: no application source or Dockerfile changed. Runtime latency and memory behavior require a post-deployment test; this task does not deploy.

## Role Assignment Verification
- Status: Unchanged and statically reviewed.
- App identity: user-assigned `app` identity.
- Role: `AcrPull`, scoped to the app's ACR.
- No role changes are required for replica or container sizing changes.

## Section 7: Validation Proof
- `terraform init -input=false` — PASS
- `terraform fmt -check main.tf` — PASS
- `terraform validate` — PASS
- `terraform plan -refresh=false -input=false -no-color` — PASS; one in-place Container App update, zero adds/destroys; no apply.
- `terraform state list` — PASS
- `terraform fmt -check -recursive` — FAIL due to pre-existing formatting in `terraform.tfvars` and `terraform copy.tfvars`; neither was modified because it is unrelated to this request.
- Azure validation wrapper — Terraform checks fail because its PowerShell helper shadows automatic `$Args`; equivalent commands above were run directly.
- JSON check skipped: `main.tfvars.json` is absent.
