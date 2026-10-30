import { createHash, randomUUID } from "node:crypto"
import { mkdir, mkdtemp, rename, rm, writeFile } from "node:fs/promises"
import os from "node:os"
import path from "node:path"

const SESSION_PREFIX = "sessions/"
const MAX_UPLOAD_ATTEMPTS = 5

function sessionIdFromBlobName(name) {
  const match = /^sessions\/(ses[A-Za-z0-9_-]+)\.json$/.exec(name)
  return match?.[1]
}

function parseJson(raw, label) {
  try {
    return JSON.parse(raw.replace(/^\uFEFF/, "").trim())
  } catch (error) {
    throw new Error(`${label} did not contain valid JSON`, { cause: error })
  }
}

function parseSessionExport(raw, expectedId) {
  const session = typeof raw === "string" ? parseJson(raw, `Session ${expectedId} export`) : raw
  if (!session?.info || session.info.id !== expectedId || !Array.isArray(session.messages)) {
    throw new Error(`Session export did not match expected session ${expectedId}`)
  }
  return session
}

function snapshotMetadata(session, content) {
  const digest = createHash("sha256").update(content).digest("hex")
  const tailIds = session.messages.map((message) => message.info?.id).filter(Boolean).slice(-10)
  return {
    updatedat: String(session.info.time?.updated ?? session.info.time?.created ?? 0),
    messagecount: String(session.messages.length),
    tailids: tailIds.join(","),
    sha256: digest,
  }
}

function snapshotDisposition(current = {}, incoming, incomingSession) {
  const currentUpdated = Number(current.updatedat ?? -1)
  const incomingUpdated = Number(incoming.updatedat ?? 0)
  const currentCount = Number(current.messagecount ?? -1)
  const incomingCount = Number(incoming.messagecount ?? 0)
  const currentTail = String(current.tailids ?? "")
  const incomingTail = String(incoming.tailids ?? "")

  if (currentUpdated > incomingUpdated || currentCount > incomingCount) return "stale"
  if (currentTail) {
    const incomingIds = new Set(incomingSession.messages.map((message) => message.info?.id).filter(Boolean))
    if (currentTail.split(",").some((id) => !incomingIds.has(id))) return "stale"
  }
  if (currentUpdated < incomingUpdated || currentCount < incomingCount) return "upload"
  if (currentTail && currentTail !== incomingTail) return "conflict"
  return current.sha256 === incoming.sha256 ? "unchanged" : "conflict"
}

function statusCode(error) {
  return error?.statusCode ?? error?.response?.status
}

async function getExistingProperties(blob) {
  try {
    return await blob.getProperties()
  } catch (error) {
    if (statusCode(error) === 404) return undefined
    throw error
  }
}

async function stageSessionExport(exportDir, session, content) {
  const target = path.join(exportDir, `${session.info.id}.json`)
  const temporary = `${target}.${process.pid}.${randomUUID()}.tmp`
  await mkdir(exportDir, { recursive: true })
  try {
    await writeFile(temporary, content, { mode: 0o600, flag: "wx" })
    await rename(temporary, target)
  } finally {
    await rm(temporary, { force: true })
  }
  return target
}

async function storeSession(containerClient, session) {
  const content = Buffer.from(JSON.stringify(session), "utf8")
  const incoming = snapshotMetadata(session, content)
  const blob = containerClient.getBlockBlobClient(`${SESSION_PREFIX}${session.info.id}.json`)

  for (let attempt = 0; attempt < MAX_UPLOAD_ATTEMPTS; attempt++) {
    const existing = await getExistingProperties(blob)
    if (existing) {
      const disposition = snapshotDisposition(existing.metadata, incoming, session)
      if (disposition !== "upload") return disposition
    }

    const conditions = existing ? { ifMatch: existing.etag } : { ifNoneMatch: "*" }
    try {
      await blob.uploadData(content, {
        blobHTTPHeaders: { blobContentType: "application/json; charset=utf-8" },
        conditions,
        metadata: incoming,
      })
      return "uploaded"
    } catch (error) {
      if (statusCode(error) !== 412 || attempt === MAX_UPLOAD_ATTEMPTS - 1) throw error
    }
  }
}

export async function backupSessions(
  containerClient,
  { runCli, dataHome = process.env.XDG_DATA_HOME, exportDir } = {},
) {
  if (typeof runCli !== "function") throw new Error("backupSessions requires a CLI runner")
  const env = { ...process.env, ...(dataHome ? { XDG_DATA_HOME: dataHome } : {}) }
  const listOutput = await runCli(["session", "list", "--format", "json"], { env })
  const listed = listOutput.trim() ? parseJson(listOutput, "Session list") : []
  if (!Array.isArray(listed)) throw new Error("OpenCode session list was not an array")

  const result = { total: listed.length, uploaded: 0, unchanged: 0, stale: 0, conflicts: 0, staged: 0, conflictIds: [], failures: [] }
  for (const item of listed) {
    const id = item?.id
    if (typeof id !== "string" || !/^ses[A-Za-z0-9_-]+$/.test(id)) {
      result.failures.push({ id: "unknown", message: "Session list contained an invalid session ID" })
      continue
    }

    try {
      const raw = await runCli(["export", id], { env })
      const session = parseSessionExport(raw, id)
      const content = Buffer.from(JSON.stringify(session), "utf8")
      if (exportDir) {
        await stageSessionExport(exportDir, session, content)
        result.staged++
      }
      const outcome = await storeSession(containerClient, session)
      const key = outcome === "conflict" ? "conflicts" : outcome
      result[key]++
      if (outcome === "conflict") result.conflictIds.push(id)
    } catch (error) {
      result.failures.push({ id, message: error.message })
    }
  }
  return result
}

export async function restoreSessions(containerClient, { runCli, dataHome = process.env.XDG_DATA_HOME } = {}) {
  if (typeof runCli !== "function") throw new Error("restoreSessions requires a CLI runner")
  const names = []
  for await (const item of containerClient.listBlobsFlat({ prefix: SESSION_PREFIX })) {
    if (sessionIdFromBlobName(item.name)) names.push(item.name)
  }
  names.sort()

  const env = { ...process.env, ...(dataHome ? { XDG_DATA_HOME: dataHome } : {}) }
  const tempDir = await mkdtemp(path.join(os.tmpdir(), "opencode-import-"))
  let imported = 0
  try {
    for (const name of names) {
      const expectedId = sessionIdFromBlobName(name)
      const content = await containerClient.getBlockBlobClient(name).downloadToBuffer()
      const session = parseSessionExport(content.toString("utf8"), expectedId)
      const inputPath = path.join(tempDir, `${expectedId}.json`)
      await writeFile(inputPath, content, { mode: 0o600 })
      await runCli(["import", inputPath], { env })
      imported++
    }
  } finally {
    await rm(tempDir, { recursive: true, force: true })
  }
  return imported
}

export async function migrateLegacySessions(
  containerClient,
  { runCli, legacyDataHome, databaseExists, exportDir } = {},
) {
  if (!legacyDataHome || typeof runCli !== "function") throw new Error("Legacy migration requires a data path and CLI runner")
  const marker = containerClient.getBlockBlobClient("control/legacy-migration-complete.json")
  if (await marker.exists()) return { migrated: false, reason: "already-complete" }
  if (!databaseExists) return { migrated: false, reason: "no-legacy-database" }

  const result = await backupSessions(containerClient, { runCli, dataHome: legacyDataHome, exportDir })
  if (result.failures.length || result.conflicts) {
    throw new Error(
      `Legacy conversation export had ${result.failures.length} failure(s) and ${result.conflicts} ambiguous conflict(s); startup blocked`,
    )
  }

  try {
    await marker.uploadData(Buffer.from(JSON.stringify({ completedAt: new Date().toISOString(), sessions: result.total })), {
      blobHTTPHeaders: { blobContentType: "application/json" },
      conditions: { ifNoneMatch: "*" },
    })
  } catch (error) {
    if (statusCode(error) !== 412) throw error
  }
  return { migrated: true, sessions: result.total }
}
