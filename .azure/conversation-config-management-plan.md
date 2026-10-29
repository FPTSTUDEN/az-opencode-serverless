# Conversation persistence and runtime configuration plan

**Tracking issue:** [#2 — Persist OpenCode conversations and externalize runtime configuration](https://github.com/FPTSTUDEN/az-opencode-serverless/issues/2)  
**Status:** Phases 1–3 are implemented and locally validated. Azure deployment, legacy-share migration verification, and phase 4 rollout/restore drills remain pending.

## Implementation progress

- Terraform provisions private `opencode-config` and `opencode-sessions` Blob containers, grants the app identity reader access to config plus contributor access to session exports, enables Blob versioning with 7-day soft-delete retention, and deletes noncurrent session blob versions after 30 days.
- `publish-config.ps1` checks JSON syntax and top-level object shape, publishes `opencode.json` as an immutable SHA-256-addressed artifact, promotes it with a small `current.json` pointer, and can restart the latest revision. OpenCode performs its own config parsing at startup. `deploy.ps1` invokes the publisher after Terraform; config-only updates do not rebuild the image or apply Terraform.
- The startup runner downloads and hash-verifies config, migrates an existing legacy share database once if found, imports session snapshots, then starts OpenCode with the live database under `/tmp`.
- The runner targets a 60-second export interval, uses ETag-conditional Blob updates and snapshot timestamp/message-tail checks to avoid replacing a newer transcript with a stale overlapping-revision snapshot, and skips ambiguous equal-timestamp divergent exports rather than selecting one arbitrarily. It attempts a final export after OpenCode exits. Export failures are logged by session ID without transcript contents.
- The selected periodic policy is best effort: recovery lag includes export duration, and an abrupt stop can lose changes since the last completed export. This is not a zero-loss handoff guarantee.
- Local runtime unit tests (12), PowerShell parsing, Terraform validation, production dependency audit (0 vulnerabilities), and a Docker image smoke test passed. No Terraform apply or Azure Blob upload has been performed as part of this implementation.

## Phase 1 validation notes

- The healthy deployed revision `opencode--0000003` reported OpenCode `1.19.4`. Revision `opencode--0000007` currently has no replica, so its exact installed version could not be queried. The previous Dockerfile installed the floating `opencode-ai` latest tag.
- Pinned the image to `opencode-ai@1.19.4`, matching the currently healthy deployed revision rather than upgrading during the persistence investigation.
- Successfully built the image locally as `opencode-phase1:1.19.4`.
- Verified the pinned CLI exposes `opencode export [sessionID]` and `opencode import <file>`. Export supports `--sanitize`; import accepts a JSON file.
- In disposable containers with an isolated local data directory, created a synthetic session and user-only transcript, exported it, imported it into a fresh database, and re-exported it. Session ID, title, `/workspace` directory, and message text were preserved.
- Imported the same 61-message export twice into an existing session database. Re-export still contained exactly 61 messages; no duplicate messages were observed. Appended a synthetic user-only message after restore and verified the restored session exported with 62 messages. This does not test a model-generated reply.
- During 60 synthetic user-only writes through the server, ran 40 CLI exports. All exports parsed as JSON and the test reported no command failures. This is a local-filesystem smoke test, not proof of safe SQLite behavior on Azure Files.
- Verified `OPENCODE_CONFIG` by starting the pinned server with a separate config file and checking that the server's effective config returned the configured model value.
- Test containers, image, and temporary export file are removed after validation. Azure Files locking characteristics, cloud Blob upload behavior, production RPO/RTO, and zero-loss revision handoff remain untested.

## Goals

- Preserve OpenCode sessions across Container Apps revision changes.
- Keep the live SQLite database on replica-local storage, not the Azure Files SMB mount.
- Keep mutable OpenCode configuration outside the container image and Terraform state.
- Keep credentials in Container Apps secrets and grant the app least-privilege access to backup/config artifacts.
- Make deployment recovery, configuration rollback, and restore behavior observable and testable.

## Proposed ownership boundaries

| Component | Owns | Does not own |
| --- | --- | --- |
| Container image | Pinned OpenCode version, startup/bootstrap tooling, runtime dependencies | Model/provider config values, credentials, conversation data |
| Terraform | Container App, managed identity, Blob container(s), RBAC, Container Apps secrets/references | Config document contents, exported sessions, mutable version pointer |
| Config repository and publishing workflow | Reviewed non-secret config, validation, immutable versioned config artifacts, promotion/rollback pointer | Secrets, live database, conversation data |
| Runtime backup/restore flow | Per-session JSON exports and import into a new local database | Config authoring, credentials, infrastructure provisioning |
| Container Apps secrets | Provider/API keys and app passwords | Non-secret OpenCode configuration or session transcripts |

## Proposed storage and flow

### Configuration

1. Keep `opencode.json` and related non-secret settings in a private, version-controlled configuration source.
2. On a config change, CI validates JSON against the OpenCode config schema and publishes an immutable artifact, for example `config/<commit-sha>/opencode.json`, to a private Blob container.
3. CI promotes a validated artifact by updating a small current-version manifest, then restarts the app so the running process reads the new config. Rollback promotes a previously validated version and restarts again.
4. At startup, the bootstrap wrapper downloads the selected config using the app's managed identity, writes it atomically to local storage, and points OpenCode at it through the supported config-file setting (verify `OPENCODE_CONFIG` for the pinned release).
5. Log the resolved config version, not config contents or secrets. If the selected artifact cannot be fetched or validated, fail startup rather than silently starting with an unintended default.

Config artifacts must contain no credentials. Provider keys and passwords remain Container Apps secrets injected into the process environment.

### Conversation persistence

1. Pin the OpenCode CLI version before implementing backups. Verify its `export`, `import`, and session-list behavior, exact JSON format, exit codes, and whether repeated imports preserve IDs or create duplicates.
2. Keep the active SQLite database under replica-local storage. Do not share its database file or WAL/SHM sidecars through Azure Files or Blob Storage.
3. Periodically list sessions and export each session to a private Blob container as JSON. Use stable object names based on session IDs and publish completed uploads atomically (temporary object then promote, or versioned object plus manifest).
4. At startup, download the latest complete export set and import it into the new local database before starting the web server or declaring the replica ready.
5. Keep export history/Blob versioning and a documented retention policy. Protect transcripts as sensitive data: private container, least-privilege RBAC, encryption, and no transcript contents in logs.
6. Treat periodic exports as an explicit recovery-point objective. Changes after the latest successful export may be lost. A strict zero-loss revision handoff requires a coordinated write freeze/drain, final export, then import; ordinary overlapping ACA rollout alone does not guarantee that ordering.

## Revision rollout and failure behavior

- The old and new revisions may overlap during startup. They use separate local databases, but both can access the same Blob backup set.
- A new revision must import only a complete, identified export generation; it must not read a partially written set.
- Define serialization/lease or generation-promotion behavior so multiple exporters cannot overwrite one another or promote stale exports.
- Do not stop the old revision until the replacement has restored successfully and passed readiness checks.
- Decide and test whether restore failure blocks readiness (recommended) or starts with an empty history. Never silently present an empty database as a successful restore.
- Record restore/export generation, timestamps, counts, and failures as metadata, without logging conversation content.

## Implementation phases

1. **Version and behavior spike**
   - Pin the OpenCode package version used by the image.
   - In a disposable environment, create sessions, export/import them, repeat imports, restart, and verify IDs, messages, project associations, and continued session use.
   - Verify `OPENCODE_CONFIG`, `opencode db path`/equivalent, and export command compatibility in the pinned release.
   - Test export while the server is active and quantify database locking/backup consistency.
2. **Config delivery**
   - Add Blob container access via managed identity and least-privilege RBAC.
   - Add config validation/publishing and promotion/rollback automation.
   - Update startup to fetch config before `opencode web`; remove mutable config from the image build.
3. **Session backup and restore**
   - Add periodic session export and Blob upload, generation metadata, retries, and operational status.
   - Import the last complete generation before server startup and gate readiness on successful restore.
   - Keep the database itself local; never copy a live SQLite file or WAL/SHM files to Blob.
4. **Rollout validation and operations**
   - Exercise revision overlap, app restart, config rollback, Blob unavailability, partial upload, failed import, and interrupted export.
   - Measure achievable recovery-point objective and recovery time; document the remaining loss window.
   - Add an operator restore drill and retention/cleanup procedure.

## Acceptance checks

- A new revision restores sessions and continues an existing conversation using the pinned OpenCode release.
- Repeated or interrupted imports do not silently duplicate/corrupt sessions; behavior is documented and tested.
- Live SQLite and sidecar files reside on local replica storage, never on Azure Files/Blob.
- Config changes can be reviewed, validated, promoted, and rolled back without rebuilding the image or editing Terraform.
- No secrets or conversation contents are baked into the image or committed to Terraform state.
- Blob access uses managed identity and least privilege; failure paths are visible and tested.
- A documented restore test demonstrates actual recovery and states the measured RPO/RTO; zero-loss is not claimed unless verified.
