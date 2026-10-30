import { BlobServiceClient } from "@azure/storage-blob"
import { createAcaIdentityCredential } from "./aca-identity.mjs"

export function createBlobService({ accountName, clientId, env = process.env, fetchImpl = fetch }) {
  if (!accountName || !/^[a-z0-9]{3,24}$/.test(accountName)) {
    throw new Error("OPENCODE_STORAGE_ACCOUNT must be a valid Azure Storage account name")
  }

  const credential = createAcaIdentityCredential({ clientId, env, fetchImpl })
  return new BlobServiceClient(`https://${accountName}.blob.core.windows.net`, credential)
}
