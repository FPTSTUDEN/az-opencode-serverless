# Azure Deployment Plan

> **Status:** Deployed

Generated: 2026-10-30

## 1. Project Overview

**Goal:** Deploy structured per-session backup and restore logging so operators can trace which session IDs were enumerated, exported, staged, stored in Blob, and imported at startup.

**Path:** Modify existing application

## 2. Requirements

| Attribute | Value |
|-----------|-------|
| Classification | Existing live application |
| Scale | Existing Container App settings; no scale change |
| Budget | Existing resources; one image build and revision update |
| Subscription | Azure for Students (4251edde-d9a9-4e8c-8855-79399bd4dc45), confirmed by user |
| Location | Sweden Central, confirmed by user |

## 3. Components Detected

| Component | Type | Technology | Path |
|-----------|------|------------|------|
| Session synchronization | Runtime support | Node.js | `runtime/session-sync.mjs`, `runtime/runner.mjs` |
| Container image | Application image | Docker / Azure Container Registry | `Dockerfile` |
| Container App | Hosting | Azure Container Apps | Existing `opencode` app |

## 4. Recipe Selection

**Selected:** Terraform with the repository's existing image-build workflow.

**Rationale:** The project selects immutable image tags through `build-image.ps1` and manages the Container App revision with Terraform. No infrastructure changes are intended.

## 5. Architecture

**Stack:** Existing containerized OpenCode application.

| Component | Azure Service | SKU |
|-----------|---------------|-----|
| OpenCode runtime | Existing Azure Container App | Existing Consumption configuration |
| Image registry | Existing Azure Container Registry | Existing Basic registry |
| Session snapshots | Existing private Blob container and Azure Files staging share | Unchanged |

No supporting services, identity assignments, secrets, storage settings, ingress, or compute settings will be changed.

## 6. Provisioning Limit Checklist

No Azure resources, SKUs, or regions are being added or changed. Quota checks are not applicable to this image/revision-only deployment.

## 7. Execution Checklist

### Phase 1: Planning
- [x] Review existing deployment and identify code-only scope.
- [x] Confirm subscription and location with user.
- [x] User approved deployment, with instruction to stop for unrelated or destructive Terraform changes.

### Phase 2: Execution
- [x] Implement structured session-ID backup and restore events; document log contents.
- [x] Run runtime tests and syntax checks.
- [x] Build immutable image `oh77b363acr.azurecr.io/opencode:567d91a30a70`; ACR build succeeded.
- [x] Review Terraform plan: only the existing Container App image changes; 0 adds, 1 change, 0 destroys.
- [x] Apply the reviewed plan; Terraform reported 0 added, 1 changed, 0 destroyed.

### Phase 3: Validation
- [x] Invoke azure-validate workflow.
- [x] All applicable validation checks pass:
  - [x] `terraform init -input=false` — PASS.
  - [x] `terraform fmt -check main.tf` — PASS; Terraform source was not changed.
  - [x] `terraform validate` — PASS.
  - [x] `terraform plan -input=false -out=deployment-logging.tfplan` — PASS; only image tag changes.
  - [x] `terraform state list` — PASS.
  - [x] Template-variable scan — PASS; `main.tfvars.json` is absent (not applicable).
  - [x] `npm --prefix runtime test` — PASS, 16 tests.
  - [x] `node --check runtime/runner.mjs`, `node --check runtime/session-sync.mjs`, and `git diff --check` — PASS.
- [x] Static and live role checks confirm the app's `AcrPull`, config-reader, and session-contributor assignments.
- [x] Revision `opencode--0000014` is Healthy, ready, and receives 100% traffic.
- [x] Startup and periodic backup logs include session IDs and per-session outcomes; no titles or transcript content appeared.

### Phase 4: Deployment
- [x] Invoke azure-deploy.
- [x] Commit after deployment verification succeeds.

## Risks and policy constraints

- Session IDs will appear in runtime logs, repeated on each periodic backup; titles and transcript content are excluded.
- This deployment must not alter configuration, data, identity/RBAC, storage, scaling, or other infrastructure.
- Stop before applying if Terraform proposes changes outside the existing Container App image/revision.

## Section 7: Validation Proof

- `npm --prefix runtime test` — PASS, 16 tests.
- `node --check runtime/runner.mjs` and `node --check runtime/session-sync.mjs` — PASS.
- `git diff --check` — PASS.
- `terraform init -input=false` — PASS.
- `terraform fmt -check main.tf` — PASS; no Terraform source was changed.
- `terraform validate` — PASS.
- `terraform state list` — PASS.
- Terraform plan saved as `deployment-logging.tfplan` — PASS; 0 adds, 1 in-place change, 0 destroys; only the Container App image changes from `c322487f8d97` to `567d91a30a70`.
- Live `AcrPull`, config-reader, and session-contributor role assignments — PASS.
- The provided Terraform validation PowerShell wrapper failed because its `Args` parameter shadows PowerShell's automatic `$Args` and invoked Terraform without subcommands. The equivalent commands above passed directly.
- Terraform emitted a pre-existing undeclared `smb_test_image_tag` variable warning from `smb-test.auto.tfvars.json`; it is unrelated to this deployment.
- ACR build `dtf` — PASS; image `oh77b363acr.azurecr.io/opencode:567d91a30a70`.
- `terraform apply -input=false -auto-approve deployment-logging.tfplan` — PASS; 0 added, 1 changed, 0 destroyed.
- Revision `opencode--0000014` — Healthy, Provisioned, 1 replica, 100% traffic; latest and latest-ready revision.
- Runtime logs — startup listed and imported `ses_e8445334dffecycCbZ0SSK3cxL` from Blob; periodic backup logged the same ID with export=ok, stage=ok, blob=unchanged.
- Ingress GET — HTTP 401, confirming the public endpoint responds and enforces app authentication.
- Post-deploy live roles — AcrPull on ACR, Storage Blob Data Reader on config container, and Storage Blob Data Contributor on session container — PASS.
