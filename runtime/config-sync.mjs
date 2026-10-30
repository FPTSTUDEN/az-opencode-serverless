import { createHash, randomUUID } from "node:crypto"
import { mkdir, rename, rm, writeFile } from "node:fs/promises"
import path from "node:path"

function parseJson(buffer, label) {
  try {
    return JSON.parse(buffer.toString("utf8").replace(/^\uFEFF/, "").trim())
  } catch (error) {
    throw new Error(`${label} did not contain valid JSON`, { cause: error })
  }
}

export async function restoreConfig(containerClient, destination) {
  const pointerBlob = containerClient.getBlockBlobClient("current.json")
  const pointer = parseJson(await pointerBlob.downloadToBuffer(), "OpenCode config pointer")
  if (typeof pointer.version !== "string" || !/^[a-f0-9]{64}$/.test(pointer.version)) {
    throw new Error("OpenCode config pointer contained an invalid version")
  }

  const content = await containerClient.getBlockBlobClient(`versions/${pointer.version}.json`).downloadToBuffer()
  const digest = createHash("sha256").update(content).digest("hex")
  if (digest !== pointer.version) throw new Error("Downloaded OpenCode config does not match its version hash")

  const config = parseJson(content, "OpenCode config")
  if (!config || typeof config !== "object" || Array.isArray(config)) {
    throw new Error("OpenCode config must be a JSON object")
  }

  await mkdir(path.dirname(destination), { recursive: true })
  const temporary = `${destination}.${randomUUID()}.tmp`
  try {
    await writeFile(temporary, content, { mode: 0o600, flag: "wx" })
    await rename(temporary, destination)
  } finally {
    await rm(temporary, { force: true })
  }
  return pointer.version
}
