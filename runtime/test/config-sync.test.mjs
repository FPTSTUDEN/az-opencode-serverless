import assert from "node:assert/strict"
import { createHash } from "node:crypto"
import { mkdtemp, readFile, rm } from "node:fs/promises"
import os from "node:os"
import path from "node:path"
import test from "node:test"
import { restoreConfig } from "../config-sync.mjs"
import { MemoryContainer } from "../helpers.mjs"

function hash(content) {
  return createHash("sha256").update(content).digest("hex")
}

test("restoreConfig verifies the immutable version and writes the selected config", async () => {
  const container = new MemoryContainer()
  const content = Buffer.from(JSON.stringify({ model: "azure/gpt-5" }))
  const version = hash(content)
  container.blobs.set("current.json", { content: Buffer.from(JSON.stringify({ version })) })
  container.blobs.set(`versions/${version}.json`, { content })
  const tempDir = await mkdtemp(path.join(os.tmpdir(), "opencode-config-test-"))
  const destination = path.join(tempDir, "nested", "opencode.json")

  try {
    assert.equal(await restoreConfig(container, destination), version)
    assert.deepEqual(JSON.parse(await readFile(destination, "utf8")), { model: "azure/gpt-5" })
  } finally {
    await rm(tempDir, { recursive: true, force: true })
  }
})

test("restoreConfig rejects a version whose content hash does not match", async () => {
  const container = new MemoryContainer()
  const expected = "a".repeat(64)
  container.blobs.set("current.json", { content: Buffer.from(JSON.stringify({ version: expected })) })
  container.blobs.set(`versions/${expected}.json`, { content: Buffer.from('{"model":"wrong"}') })
  await assert.rejects(() => restoreConfig(container, path.join(os.tmpdir(), "unused.json")), /does not match its version hash/)
})
