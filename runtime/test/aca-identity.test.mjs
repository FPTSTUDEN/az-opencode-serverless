import assert from "node:assert/strict"
import test from "node:test"
import { createAcaIdentityCredential } from "../aca-identity.mjs"

test("ACA identity credential requests and caches a storage token for the user-assigned identity", async () => {
  let requests = 0
  const credential = createAcaIdentityCredential({
    clientId: "client-id",
    env: { IDENTITY_ENDPOINT: "http://identity/token", IDENTITY_HEADER: "header-secret" },
    async fetchImpl(url, options) {
      requests++
      const parsed = new URL(url)
      assert.equal(parsed.searchParams.get("api-version"), "2019-08-01")
      assert.equal(parsed.searchParams.get("resource"), "https://storage.azure.com/")
      assert.equal(parsed.searchParams.get("client_id"), "client-id")
      assert.equal(options.headers["X-IDENTITY-HEADER"], "header-secret")
      return {
        ok: true,
        async json() {
          return { access_token: "token", expires_on: String(Math.floor(Date.now() / 1000) + 3600) }
        },
      }
    },
  })

  const first = await credential.getToken(["https://storage.azure.com/.default"])
  const second = await credential.getToken(["https://storage.azure.com/.default"])
  assert.equal(first.token, "token")
  assert.equal(second.token, "token")
  assert.equal(requests, 1)
})

test("ACA identity credential rejects missing endpoint and non-storage scopes", async () => {
  assert.throws(() => createAcaIdentityCredential({ env: {} }), /endpoint is unavailable/)
  const credential = createAcaIdentityCredential({
    env: { IDENTITY_ENDPOINT: "http://identity/token", IDENTITY_HEADER: "header-secret" },
  })
  await assert.rejects(() => credential.getToken(["https://management.azure.com/.default"]), /only supports Azure Storage/)
})
