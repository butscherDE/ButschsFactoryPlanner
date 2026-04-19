$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$InfoJson = Join-Path $ScriptDir "modfiles\info.json"

if (-not (Test-Path $InfoJson)) {
    Write-Error "info.json not found at $InfoJson"
    exit 1
}

$Info = Get-Content $InfoJson -Raw | ConvertFrom-Json
$ModName = $Info.name
$ModVersion = $Info.version
$ModFolder = "${ModName}_${ModVersion}"

$ModsDir = Join-Path $env:APPDATA "Factorio\mods"

if (-not (Test-Path $ModsDir)) {
    Write-Error "Factorio mods directory not found at $ModsDir. Is Factorio installed?"
    exit 1
}

$Target = Join-Path $ModsDir $ModFolder

# Remove any existing versions of the mod (including different version numbers)
Get-ChildItem -Path $ModsDir -Directory -Filter "${ModName}_*" | ForEach-Object {
    Write-Host "Removing old version $($_.Name) ..."
    Remove-Item -Recurse -Force $_.FullName
}

Write-Host "Deploying $ModFolder to $ModsDir ..."
Copy-Item -Recurse (Join-Path $ScriptDir "modfiles") $Target

Write-Host "Done. Enable '$ModName' in Factorio's mod manager."
