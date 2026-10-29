$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
Push-Location $root
try {
    # Bootstrap only the resource group and registry before the first image build.
    terraform apply -auto-approve `
        -target=azurerm_resource_group.rg `
        -target=azurerm_container_registry.acr
    if ($LASTEXITCODE -ne 0) { throw "Terraform ACR bootstrap failed." }

    .\build-image.ps1
    if ($LASTEXITCODE -ne 0) { throw "Container image build failed." }

    terraform apply -auto-approve
    if ($LASTEXITCODE -ne 0) { throw "Terraform deployment failed." }

    .\publish-config.ps1 -Restart
    if ($LASTEXITCODE -ne 0) { throw "OpenCode config publication or revision restart failed." }
}
finally {
    Pop-Location
}
