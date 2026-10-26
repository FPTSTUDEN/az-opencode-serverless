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
    $dockerfileHash = (Get-FileHash (Join-Path $root "Dockerfile") -Algorithm SHA256).Hash
    $configHash = (Get-FileHash (Join-Path $root "opencode.json") -Algorithm SHA256).Hash
    $credentialHelperHash = (Get-FileHash (Join-Path $root "git-credential-github-token") -Algorithm SHA256).Hash
    $combined = [System.Text.Encoding]::UTF8.GetBytes($dockerfileHash + $configHash + $credentialHelperHash)
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
