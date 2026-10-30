import assert from "node:assert/strict"
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises"
import os from "node:os"
import path from "node:path"
import test from "node:test"
import { backupSessions, migrateLegacySessions, restoreSessions } from "../session-sync.mjs"
import { MemoryContainer, session } from "../helpers.mjs"

const sessionId = "ses_test-session_1"

function cliFor(current, expectedDataHome = "/tmp/test-data") {
  const imports = []
  return {
    imports,
    async runCli(args, { env } = {}) {
      if (args[0] === "session") {
        assert.equal(env.XDG_DATA_HOME, expectedDataHome)
        return JSON.stringify([{ id: sessionId }])
      }
      if (args[0] === "export") return JSON.stringify(current.value)
      if (args[0] === "import") imports.push(JSON.parse(await readFile(args[1], "utf8")))
      return ""
    },
  }
}

test("backup stores new exports and refuses to overwrite a newer session", async () => {
  const container = new MemoryContainer()
  const current = { value: session(sessionId, { updated: 20, messages: [{ info: { id: "msg1" } }] }) }
  const cli = cliFor(current)
  const first = await backupSessions(container, { runCli: cli.runCli, dataHome: "/tmp/test-data" })
  assert.deepEqual(first, { total: 1, uploaded: 1, unchanged: 0, stale: 0, conflicts: 0, staged: 0, conflictIds: [], failures: [] })

  const repeated = await backupSessions(container, { runCli: cli.runCli, dataHome: "/tmp/test-data" })
  assert.equal(repeated.unchanged, 1)
  current.value = session(sessionId, { updated: 10 })
  const stale = await backupSessions(container, { runCli: cli.runCli, dataHome: "/tmp/test-data" })
  assert.equal(stale.stale, 1)

  const stored = JSON.parse((await container.getBlockBlobClient(`sessions/${sessionId}.json`).downloadToBuffer()).toString())
  assert.equal(stored.info.time.updated, 20)
  assert.equal(stored.messages.length, 1)
})

test("backup emits IDs and per-session outcomes without transcript content", async () => {
  const container = new MemoryContainer()
  const current = {
    value: session(sessionId, {
      updated: 20,
      messages: [{ info: { id: "msg1" }, parts: [{ text: "private transcript" }] }],
    }),
  }
  const cli = cliFor(current)
  const exportDir = await mkdtemp(path.join(os.tmpdir(), "opencode-export-events-test-"))
  const events = []
  try {
    await backupSessions(container, {
      runCli: cli.runCli,
      dataHome: "/tmp/test-data",
      exportDir,
      onEvent: (event) => events.push(event),
    })
    assert.deepEqual(events, [
      { event: "backup.session_list", count: 1, sessionIds: [sessionId], invalidCount: 0 },
      { event: "backup.session", sessionId, export: "ok", stage: "ok", blob: "uploaded" },
    ])
    assert.equal(JSON.stringify(events).includes("private transcript"), false)
  } finally {
    await rm(exportDir, { recursive: true, force: true })
  }
})

test("backup refuses a newer-looking snapshot that omits the current transcript tail", async () => {
  const container = new MemoryContainer()
  const current = {
    value: session(sessionId, {
      updated: 20,
      messages: [{ info: { id: "msg1" } }, { info: { id: "msg2" } }],
    }),
  }
  const cli = cliFor(current)
  await backupSessions(container, { runCli: cli.runCli, dataHome: "/tmp/test-data" })

  current.value = session(sessionId, {
    updated: 30,
    messages: [{ info: { id: "msg1" } }, { info: { id: "msg3" } }],
  })
  const result = await backupSessions(container, { runCli: cli.runCli, dataHome: "/tmp/test-data" })
  assert.equal(result.stale, 1)
  const stored = JSON.parse((await container.getBlockBlobClient(`sessions/${sessionId}.json`).downloadToBuffer()).toString())
  assert.deepEqual(stored.messages.map((message) => message.info.id), ["msg1", "msg2"])
})

test("backup stages the latest conflicting export on the mounted share", async () => {
  const container = new MemoryContainer()
  const tempDir = await mkdtemp(path.join(os.tmpdir(), "opencode-export-stage-test-"))
  const current = { value: session(sessionId, { updated: 20, messages: [{ info: { id: "msg1" }, parts: [{ text: "old" }] }] }) }
  const cli = cliFor(current)
  const options = { runCli: cli.runCli, dataHome: "/tmp/test-data", exportDir: tempDir }
  try {
    await backupSessions(container, options)
    current.value = session(sessionId, {
      updated: 20,
      messages: [{ info: { id: "msg1" }, parts: [{ text: "in-progress reply" }] }],
    })
    const result = await backupSessions(container, options)
    assert.equal(result.staged, 1)
    assert.equal(result.conflicts, 1)
    assert.deepEqual(result.conflictIds, [sessionId])

    const stagedPath = path.join(tempDir, `${sessionId}.json`)
    const staged = JSON.parse(await readFile(stagedPath, "utf8"))
    assert.equal(staged.messages[0].parts[0].text, "in-progress reply")
  } finally {
    await rm(tempDir, { recursive: true, force: true })
  }
})

test("backup skips divergent snapshots with the same timestamp and message tail", async () => {
  const container = new MemoryContainer()
  const current = {
    value: session(sessionId, {
      updated: 20,
      messages: [{ info: { id: "msg1" }, parts: [{ text: "old" }] }],
    }),
  }
  const cli = cliFor(current)
  await backupSessions(container, { runCli: cli.runCli, dataHome: "/tmp/test-data" })

  current.value = session(sessionId, {
    updated: 20,
    messages: [{ info: { id: "msg1" }, parts: [{ text: "divergent" }] }],
  })
  const result = await backupSessions(container, { runCli: cli.runCli, dataHome: "/tmp/test-data" })
  assert.equal(result.conflicts, 1)
  const stored = JSON.parse((await container.getBlockBlobClient(`sessions/${sessionId}.json`).downloadToBuffer()).toString())
  assert.equal(stored.messages[0].parts[0].text, "old")
})

test("backup treats the CLI's empty session output as an empty collection", async () => {
  const container = new MemoryContainer()
  const result = await backupSessions(container, {
    dataHome: "/tmp/test-data",
    async runCli() {
      return ""
    },
  })
  assert.deepEqual(result, { total: 0, uploaded: 0, unchanged: 0, stale: 0, conflicts: 0, staged: 0, conflictIds: [], failures: [] })
})

test("restore imports valid sessions from private snapshots and ignores control blobs", async () => {
  const container = new MemoryContainer()
  const archived = session(sessionId, { updated: 30, messages: [{ id: "msg1" }] })
  container.blobs.set(`sessions/${sessionId}.json`, { content: Buffer.from(JSON.stringify(archived)) })
  container.blobs.set("control/legacy-migration-complete.json", { content: Buffer.from("{}") })
  const tempHome = await mkdtemp(path.join(os.tmpdir(), "opencode-restore-test-"))
  const imports = []
  const events = []
  try {
    const count = await restoreSessions(container, {
      dataHome: tempHome,
      exportDir: path.join(tempHome, "exports"),
      onEvent: (event) => events.push(event),
      async runCli(args, { env }) {
        assert.equal(env.XDG_DATA_HOME, tempHome)
        if (args[0] === "import") imports.push(JSON.parse(await readFile(args[1], "utf8")))
      },
    })
    assert.deepEqual(count, { imported: 1, stagedRecovered: 0, stagedIgnored: 0 })
    assert.deepEqual(events, [
      { event: "restore.session_list", count: 1, sessionIds: [sessionId] },
      {
        event: "restore.session",
        sessionId,
        blobCandidate: true,
        stagedCandidate: false,
        stage: "absent",
        source: "blob",
        import: "ok",
      },
    ])
    assert.equal(imports[0].info.id, sessionId)
    assert.equal(imports[0].messages.length, 1)
  } finally {
    await rm(tempHome, { recursive: true, force: true })
  }
})

test("restore prefers and promotes a staged conflict snapshot before importing", async () => {
  const container = new MemoryContainer()
  const id = sessionId
  const blobSession = session(id, { updated: 20, messages: [{ info: { id: "msg1" }, parts: [{ text: "old" }] }] })
  container.blobs.set(`sessions/${id}.json`, {
    content: Buffer.from(JSON.stringify(blobSession)),
    metadata: { updatedat: "20", messagecount: "1", tailids: "msg1", sha256: "old-hash" },
    etag: "etag-blob",
  })
  const stagedSession = session(id, {
    updated: 20,
    messages: [{ info: { id: "msg1" }, parts: [{ text: "recovered in-progress turn" }] }],
  })
  const stagedContent = Buffer.from(JSON.stringify(stagedSession))
  const exportDir = await mkdtemp(path.join(os.tmpdir(), "opencode-staged-recovery-test-"))
  await writeFile(path.join(exportDir, `${id}.json`), stagedContent)
  const imports = []
  const events = []
  try {
    const result = await restoreSessions(container, {
      exportDir,
      dataHome: "/tmp/recovery-data",
      onEvent: (event) => events.push(event),
      async runCli(args) {
        if (args[0] === "import") imports.push(JSON.parse(await readFile(args[1], "utf8")))
      },
    })
    assert.deepEqual(result, { imported: 1, stagedRecovered: 1, stagedIgnored: 0 })
    assert.deepEqual(events[1], {
      event: "restore.session",
      sessionId: id,
      blobCandidate: true,
      stagedCandidate: true,
      stage: "present",
      source: "staged",
      import: "ok",
    })
    assert.equal(imports[0].messages[0].parts[0].text, "recovered in-progress turn")
    const persisted = JSON.parse((await container.getBlockBlobClient(`sessions/${id}.json`).downloadToBuffer()).toString())
    assert.equal(persisted.messages[0].parts[0].text, "recovered in-progress turn")
    assert.equal((await readFile(path.join(exportDir, `${id}.json`))).toString(), stagedContent.toString())
  } finally {
    await rm(exportDir, { recursive: true, force: true })
  }
})

test("restore keeps the newer Blob snapshot when staged data is stale", async () => {
  const container = new MemoryContainer()
  const id = sessionId
  const blobSession = session(id, { updated: 30, messages: [{ info: { id: "msg1" } }, { info: { id: "msg2" } }] })
  const blobContent = Buffer.from(JSON.stringify(blobSession))
  container.blobs.set(`sessions/${id}.json`, {
    content: blobContent,
    metadata: { updatedat: "30", messagecount: "2", tailids: "msg1,msg2", sha256: "newer-hash" },
    etag: "etag-newer",
  })
  const exportDir = await mkdtemp(path.join(os.tmpdir(), "opencode-stale-stage-test-"))
  await writeFile(path.join(exportDir, `${id}.json`), JSON.stringify(session(id, { updated: 20, messages: [{ info: { id: "msg1" } }] })))
  const imports = []
  try {
    const result = await restoreSessions(container, {
      exportDir,
      async runCli(args) {
        if (args[0] === "import") imports.push(JSON.parse(await readFile(args[1], "utf8")))
      },
    })
    assert.deepEqual(result, { imported: 1, stagedRecovered: 0, stagedIgnored: 0 })
    assert.equal(imports[0].messages.length, 2)
  } finally {
    await rm(exportDir, { recursive: true, force: true })
  }
})

test("legacy migration exports once and records completion only after success", async () => {
  const container = new MemoryContainer()
  const cli = cliFor({ value: session(sessionId) }, "/workspace/.opencode-data")
  const options = { runCli: cli.runCli, legacyDataHome: "/workspace/.opencode-data", databaseExists: true }
  const first = await migrateLegacySessions(container, options)
  assert.deepEqual(first, { migrated: true, sessions: 1 })
  const second = await migrateLegacySessions(container, options)
  assert.deepEqual(second, { migrated: false, reason: "already-complete" })
  assert.equal(container.blobs.has("control/legacy-migration-complete.json"), true)
})

test("legacy migration blocks on ambiguous snapshots and does not mark completion", async () => {
  const container = new MemoryContainer()
  const current = { value: session(sessionId, { updated: 20, messages: [{ info: { id: "msg1" }, parts: [{ text: "old" }] }] }) }
  const cli = cliFor(current, "/workspace/.opencode-data")
  await backupSessions(container, { runCli: cli.runCli, dataHome: "/workspace/.opencode-data" })
  current.value = session(sessionId, {
    updated: 20,
    messages: [{ info: { id: "msg1" }, parts: [{ text: "different" }] }],
  })

  await assert.rejects(
    () => migrateLegacySessions(container, {
      runCli: cli.runCli,
      legacyDataHome: "/workspace/.opencode-data",
      databaseExists: true,
    }),
    /ambiguous conflict.*startup blocked/,
  )
  assert.equal(container.blobs.has("control/legacy-migration-complete.json"), false)
})

test("legacy migration does not mark completion when the legacy database is absent", async () => {
  const container = new MemoryContainer()
  const result = await migrateLegacySessions(container, {
    runCli: async () => assert.fail("CLI should not run without a legacy database"),
    legacyDataHome: "/workspace/.opencode-data",
    databaseExists: false,
  })
  assert.deepEqual(result, { migrated: false, reason: "no-legacy-database" })
  assert.equal(container.blobs.has("control/legacy-migration-complete.json"), false)
})
