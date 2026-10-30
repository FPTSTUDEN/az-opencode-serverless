import { execFile, spawn } from "node:child_process"
import { existsSync } from "node:fs"
import { mkdir } from "node:fs/promises"
import os from "node:os"
import path from "node:path"
import { promisify } from "node:util"
import { setTimeout as delay } from "node:timers/promises"
import { createBlobService } from "./blob-client.mjs"
import { restoreConfig } from "./config-sync.mjs"
import { migrateLegacySessions, backupSessions, restoreSessions } from "./session-sync.mjs"

const execFileAsync = promisify(execFile)
const BACKUP_INTERVAL_MS = 60_000
const MAX_CLI_BUFFER = 128 * 1024 * 1024
const BOOTSTRAP_ATTEMPTS = 8
const dataHome = path.join(os.tmpdir(), "opencode-data")
const configPath = path.join(os.tmpdir(), "opencode-config", "opencode.json")
const legacyDataHome = "/workspace/.opencode-data"
const exportDir = "/workspace/.opencode-exports"

function required(name) {
  const value = process.env[name]
  if (!value) throw new Error(`${name} must be configured`)
  return value
}

async function runCli(args, { env = process.env } = {}) {
  const { stdout } = await execFileAsync("opencode", args, {
    encoding: "utf8",
    env,
    maxBuffer: MAX_CLI_BUFFER,
    timeout: 120_000,
  })
  return stdout
}

function log(message) {
  console.log(`[state-sync] ${message}`)
}

async function start() {
  process.env.XDG_DATA_HOME = dataHome
  process.env.XDG_CONFIG_HOME = path.join(os.tmpdir(), "opencode-config-home")
  process.env.XDG_CACHE_HOME = path.join(os.tmpdir(), "opencode-cache")
  process.env.XDG_STATE_HOME = path.join(os.tmpdir(), "opencode-state")
  await Promise.all(
    [dataHome, process.env.XDG_CONFIG_HOME, process.env.XDG_CACHE_HOME, process.env.XDG_STATE_HOME].map((dir) =>
      mkdir(dir, { recursive: true }),
    ),
  )

  const service = createBlobService({
    accountName: required("OPENCODE_STORAGE_ACCOUNT"),
    clientId: required("AZURE_CLIENT_ID"),
  })
  const configContainer = service.getContainerClient(required("OPENCODE_CONFIG_CONTAINER"))
  const sessionsContainer = service.getContainerClient(required("OPENCODE_SESSION_CONTAINER"))

  const legacyDatabase = path.join(legacyDataHome, "opencode", "opencode.db")
  let configVersion
  let migration
  let restored
  for (let attempt = 1; attempt <= BOOTSTRAP_ATTEMPTS; attempt++) {
    try {
      configVersion = await restoreConfig(configContainer, configPath)
      process.env.OPENCODE_CONFIG = configPath
      migration = await migrateLegacySessions(sessionsContainer, {
        runCli,
        legacyDataHome,
        databaseExists: existsSync(legacyDatabase),
        exportDir,
      })
      restored = await restoreSessions(sessionsContainer, { runCli, dataHome, exportDir })
      break
    } catch (error) {
      if (attempt === BOOTSTRAP_ATTEMPTS) throw error
      const waitMs = Math.min(2_000 * 2 ** (attempt - 1), 30_000)
      log(`bootstrap attempt ${attempt} failed (${error.message}); retrying in ${waitMs}ms`)
      await delay(waitMs)
    }
  }
  log(`loaded config version ${configVersion}`)
  if (migration.migrated) log(`migrated ${migration.sessions} legacy session(s) to Blob Storage`)
  log(`restored ${restored.imported} session(s); recovered ${restored.stagedRecovered} from staged exports; ignored ${restored.stagedIgnored} invalid staged export(s)`)

  const [command, ...args] = process.argv.slice(2)
  if (!command) throw new Error("No OpenCode server command was provided")
  const child = spawn(command, args, { stdio: "inherit", env: process.env })

  let activeBackup
  const backup = async (kind) => {
    if (activeBackup) return activeBackup
    activeBackup = backupSessions(sessionsContainer, { runCli, dataHome, exportDir })
      .then((result) => {
        log(`${kind} backup: ${result.staged} staged at ${exportDir}, ${result.uploaded} uploaded, ${result.unchanged} unchanged, ${result.stale} stale skipped, ${result.conflicts} concurrent conflicts skipped, ${result.failures.length} failed`)
        for (const id of result.conflictIds) log(`session ${id} conflict snapshot preserved at ${exportDir}/${id}.json`)
        for (const failure of result.failures) log(`session ${failure.id} export failed: ${failure.message}`)
      })
      .catch((error) => log(`${kind} backup failed: ${error.message}`))
      .finally(() => {
        activeBackup = undefined
      })
    return activeBackup
  }

  const timer = setInterval(() => void backup("periodic"), BACKUP_INTERVAL_MS)
  timer.unref()

  const exit = new Promise((resolve, reject) => {
    child.once("error", reject)
    child.once("exit", (code, signal) => resolve({ code, signal }))
  })
  const forwardSignal = (signal) => {
    if (child.exitCode === null && !child.killed) child.kill(signal)
  }
  process.on("SIGTERM", forwardSignal)
  process.on("SIGINT", forwardSignal)

  let result
  try {
    result = await exit
  } finally {
    clearInterval(timer)
    process.off("SIGTERM", forwardSignal)
    process.off("SIGINT", forwardSignal)
    if (activeBackup) await activeBackup
    await backup("shutdown")
  }

  if (result.signal) {
    log(`OpenCode exited after ${result.signal}`)
    process.exitCode = 1
  } else {
    process.exitCode = result.code ?? 1
  }
}

start().catch((error) => {
  console.error(`[state-sync] startup failed: ${error.message}`)
  process.exitCode = 1
})
