param(
    [string]$RegistryName,

    [string]$Tag
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path

if (-not $RegistryName) {
    $RegistryName = (& terraform "-chdir=$root" output -raw acr_name 2>$null).Trim()
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($RegistryName)) {
        throw "ACR does not exist yet. Run .\deploy.ps1 for first-time provisioning, or pass -RegistryName explicitly."
    }
}

if (-not $Tag) {
    $imageInputs = @(
        ".dockerignore",
        "Dockerfile",
        "start-opencode",
        "runtime/package.json",
        "runtime/package-lock.json",
        "runtime/aca-identity.mjs",
        "runtime/blob-client.mjs",
        "runtime/config-sync.mjs",
        "runtime/session-sync.mjs",
        "runtime/runner.mjs"
    )
    $inputHashes = foreach ($path in $imageInputs) {
        $fileHash = (Get-FileHash (Join-Path $root $path) -Algorithm SHA256).Hash.ToLowerInvariant()
        "$path`:$fileHash"
    }
    $combined = [System.Text.Encoding]::UTF8.GetBytes($inputHashes -join "`n")
    $combinedHash = [System.Security.Cryptography.SHA256]::Create().ComputeHash($combined)
    $tagHash = ([System.BitConverter]::ToString($combinedHash) -replace "-", "").Substring(0, 12).ToLowerInvariant()
    $Tag = "opencode:$tagHash"
}

$env:PYTHONIOENCODING = "utf-8"
az acr build `
    --registry $RegistryName `
    --image $Tag `
    --no-logs `
    $root

if ($LASTEXITCODE -ne 0) {
    throw "Azure Container Registry image build failed with exit code $LASTEXITCODE."
}

$imageTag = $Tag.Split(":")[-1]
@{ image_tag = $imageTag } | ConvertTo-Json | Set-Content `
    (Join-Path $root "image.auto.tfvars.json") -Encoding utf8

Write-Host "Built $Tag and selected it for the next Terraform apply."
