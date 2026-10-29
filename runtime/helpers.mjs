export class MemoryContainer {
  blobs = new Map()
  etag = 0

  getBlockBlobClient(name) {
    const container = this
    return {
      async exists() {
        return container.blobs.has(name)
      },
      async getProperties() {
        const current = container.blobs.get(name)
        if (!current) throw Object.assign(new Error("Not found"), { statusCode: 404 })
        return { etag: current.etag, metadata: current.metadata }
      },
      async downloadToBuffer() {
        const current = container.blobs.get(name)
        if (!current) throw Object.assign(new Error("Not found"), { statusCode: 404 })
        return Buffer.from(current.content)
      },
      async uploadData(data, options = {}) {
        const current = container.blobs.get(name)
        if (options.conditions?.ifNoneMatch === "*" && current) {
          throw Object.assign(new Error("Already exists"), { statusCode: 412 })
        }
        if (options.conditions?.ifMatch && options.conditions.ifMatch !== current?.etag) {
          throw Object.assign(new Error("ETag mismatch"), { statusCode: 412 })
        }
        container.etag++
        container.blobs.set(name, {
          content: Buffer.from(data),
          etag: `etag-${container.etag}`,
          metadata: options.metadata ?? {},
        })
      },
    }
  }

  async *listBlobsFlat({ prefix = "" } = {}) {
    for (const name of this.blobs.keys()) {
      if (name.startsWith(prefix)) yield { name }
    }
  }
}

export function session(id, { updated = 10, messages = [] } = {}) {
  return {
    info: {
      id,
      slug: "test-session",
      projectID: "global",
      directory: "/workspace",
      title: "test session",
      time: { created: 1, updated },
    },
    messages,
  }
}
