# Deployment Plan

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
