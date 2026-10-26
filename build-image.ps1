param(
    [Parameter(Mandatory = $true)]
    [string]$RegistryName,

    [string]$Tag = "opencode:latest"
)

$ErrorActionPreference = "Stop"

$env:PYTHONIOENCODING = "utf-8"
az acr build `
    --registry $RegistryName `
    --image $Tag `
    --no-logs `
    (Split-Path -Parent $MyInvocation.MyCommand.Path)

if ($LASTEXITCODE -ne 0) {
    throw "Azure Container Registry image build failed with exit code $LASTEXITCODE."
}
