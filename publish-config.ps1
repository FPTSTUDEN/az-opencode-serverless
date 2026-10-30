param(
    [string]$StorageAccountName,
    [string]$ContainerName,
    [string]$ResourceGroupName,
    [string]$ConfigPath,
    [switch]$Restart
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path

if (-not $StorageAccountName) {
    $StorageAccountName = (& terraform "-chdir=$root" output -raw storage_account_name 2>$null).Trim()
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($StorageAccountName)) {
        throw "Terraform output storage_account_name is unavailable. Apply infrastructure first or pass -StorageAccountName."
    }
}
if (-not $ContainerName) {
    $ContainerName = (& terraform "-chdir=$root" output -raw opencode_config_container_name 2>$null).Trim()
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($ContainerName)) {
        throw "Terraform output opencode_config_container_name is unavailable. Apply infrastructure first or pass -ContainerName."
    }
}
if (-not $ResourceGroupName) {
    $ResourceGroupName = (& terraform "-chdir=$root" output -raw resource_group_name 2>$null).Trim()
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($ResourceGroupName)) {
        throw "Terraform output resource_group_name is unavailable. Apply infrastructure first or pass -ResourceGroupName."
    }
}
if (-not $ConfigPath) {
    $ConfigPath = Join-Path $root "opencode.json"
}
if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
    throw "Config file not found: $ConfigPath"
}

try {
    $config = Get-Content -Raw -LiteralPath $ConfigPath | ConvertFrom-Json -ErrorAction Stop
} catch {
    throw "OpenCode config is not valid JSON: $($_.Exception.Message)"
}
if ($null -eq $config -or $config -is [array] -or $config -is [string] -or $config -is [ValueType]) {
    throw "OpenCode config must be a JSON object."
}

$version = (Get-FileHash -LiteralPath $ConfigPath -Algorithm SHA256).Hash.ToLowerInvariant()
$versionBlob = "versions/$version.json"
$exists = & az storage blob exists `
    --account-name $StorageAccountName `
    --container-name $ContainerName `
    --name $versionBlob `
    --auth-mode login `
    --query exists `
    --output tsv
if ($LASTEXITCODE -ne 0) {
    throw "Could not check config artifact in Blob Storage. Sign in with az login and ensure the publisher has Storage Blob Data Contributor access."
}

if ($exists -ne "true") {
    & az storage blob upload `
        --account-name $StorageAccountName `
        --container-name $ContainerName `
        --name $versionBlob `
        --file $ConfigPath `
        --auth-mode login `
        --overwrite false `
        --only-show-errors
    if ($LASTEXITCODE -ne 0) {
        throw "Could not upload immutable config version $version."
    }
}

$manifestPath = [System.IO.Path]::GetTempFileName()
try {
    $manifest = @{ version = $version } | ConvertTo-Json -Compress
    [System.IO.File]::WriteAllText($manifestPath, $manifest, [System.Text.UTF8Encoding]::new($false))
    & az storage blob upload `
        --account-name $StorageAccountName `
        --container-name $ContainerName `
        --name "current.json" `
        --file $manifestPath `
        --auth-mode login `
        --overwrite true `
        --content-type "application/json" `
        --only-show-errors
    if ($LASTEXITCODE -ne 0) {
        throw "Could not promote config version $version. The previous current version remains selected."
    }
} finally {
    Remove-Item -LiteralPath $manifestPath -Force -ErrorAction SilentlyContinue
}

Write-Host "Published OpenCode config version $version to $StorageAccountName/$ContainerName."
if ($Restart) {
    $revision = (& az containerapp show `
        --name "opencode" `
        --resource-group $ResourceGroupName `
        --query "properties.latestRevisionName" `
        --output tsv).Trim()
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($revision)) {
        throw "Config published, but the latest ready revision could not be resolved for restart."
    }
    $replicas = & az containerapp revision show `
        --name "opencode" `
        --resource-group $ResourceGroupName `
        --revision $revision `
        --query "properties.replicas" `
        --output tsv
    if ($LASTEXITCODE -ne 0) {
        throw "Config published, but the replica count for revision $revision could not be read."
    }
    if ([int]$replicas -gt 0) {
        & az containerapp revision restart --name "opencode" --resource-group $ResourceGroupName --revision $revision
        if ($LASTEXITCODE -ne 0) {
            throw "Config published, but restarting revision $revision failed."
        }
        Write-Host "Restarted revision $revision to load the new config."
    } else {
        Write-Host "Revision $revision has no active replicas; its next start will load the new config."
    }
} else {
    Write-Host "Run .\publish-config.ps1 -Restart to restart the latest ready revision, or let the app scale down and start with this config."
}
