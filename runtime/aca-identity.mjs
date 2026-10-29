const STORAGE_RESOURCE = "https://storage.azure.com/"
const TOKEN_REFRESH_SKEW_MS = 120_000

function expirationTimestamp(body) {
  const expiresOn = Number(body.expires_on)
  if (Number.isFinite(expiresOn) && expiresOn > 0) return expiresOn < 1_000_000_000_000 ? expiresOn * 1000 : expiresOn
  const parsed = Date.parse(body.expires_on)
  if (Number.isFinite(parsed)) return parsed
  const expiresIn = Number(body.expires_in)
  if (Number.isFinite(expiresIn) && expiresIn > 0) return Date.now() + expiresIn * 1000
  throw new Error("Managed identity response did not include a valid token expiration")
}

export function createAcaIdentityCredential({ clientId, env = process.env, fetchImpl = fetch } = {}) {
  const endpoint = env.IDENTITY_ENDPOINT
  const identityHeader = env.IDENTITY_HEADER
  if (!endpoint || !identityHeader) {
    throw new Error("Azure Container Apps managed identity endpoint is unavailable")
  }

  let cachedToken
  let pendingRequest

  return {
    async getToken(scopes, options = {}) {
      if (!Array.isArray(scopes) || scopes.length === 0 || scopes.some((scope) => !scope.startsWith(STORAGE_RESOURCE))) {
        throw new Error("The Container Apps credential only supports Azure Storage tokens")
      }

      if (cachedToken && cachedToken.expiresOnTimestamp - Date.now() > TOKEN_REFRESH_SKEW_MS) return cachedToken
      if (pendingRequest) return pendingRequest

      pendingRequest = (async () => {
        const url = new URL(endpoint)
        url.searchParams.set("api-version", "2019-08-01")
        url.searchParams.set("resource", STORAGE_RESOURCE)
        if (clientId) url.searchParams.set("client_id", clientId)

        const response = await fetchImpl(url, {
          headers: { "X-IDENTITY-HEADER": identityHeader },
          signal: options.abortSignal,
        })
        if (!response.ok) throw new Error(`Managed identity token request failed with HTTP ${response.status}`)

        const body = await response.json()
        if (typeof body.access_token !== "string" || !body.access_token) {
          throw new Error("Managed identity response did not contain an access token")
        }
        cachedToken = { token: body.access_token, expiresOnTimestamp: expirationTimestamp(body) }
        return cachedToken
      })()

      try {
        return await pendingRequest
      } finally {
        pendingRequest = undefined
      }
    },
  }
}
