$ErrorActionPreference = "Stop"

# Installs a pinned GitHub release. Never follows /releases/latest.
# Override the pin with TREEHOUSE_VERSION=vX.Y.Z (still checksum-verified).
$repo = "kunchenguid/treehouse"
$pinnedVersion = "v2.1.1"
$version = if ($env:TREEHOUSE_VERSION) { $env:TREEHOUSE_VERSION } else { $pinnedVersion }

# Reject unpinned or path-like values so the download URL cannot drift to
# /releases/latest or escape the releases/download/<tag>/ prefix.
if ($version -notmatch '^v[0-9][A-Za-z0-9._-]*$') {
    throw "Invalid TREEHOUSE_VERSION: $version (expected vX.Y.Z)"
}

$installDir = "$env:LOCALAPPDATA\treehouse"

$arch = if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { "arm64" } else { "amd64" }

$versionNum = $version.TrimStart("v")
$filename = "treehouse-v$versionNum-windows-$arch.zip"
$releaseBase = "https://github.com/$repo/releases/download/$version"
$url = "$releaseBase/$filename"
$checksumsUrl = "$releaseBase/checksums.txt"

$tmpDir = New-TemporaryFile | ForEach-Object { Remove-Item $_; New-Item -ItemType Directory -Path $_ }

Write-Host "Downloading treehouse $version for windows/$arch..."
Invoke-WebRequest -Uri $url -OutFile "$tmpDir\$filename"

Write-Host "Verifying SHA-256 against $checksumsUrl..."
try {
    Invoke-WebRequest -Uri $checksumsUrl -OutFile "$tmpDir\checksums.txt"
} catch {
    throw "Failed to download checksums.txt; refusing to install"
}

if (-not (Test-Path "$tmpDir\checksums.txt") -or (Get-Item "$tmpDir\checksums.txt").Length -eq 0) {
    throw "checksums.txt is missing or empty; refusing to install"
}

$expectedLine = Get-Content "$tmpDir\checksums.txt" | Where-Object {
    $_ -match ('^[0-9a-fA-F]{64}\s+\*?' + [regex]::Escape($filename) + '\s*$')
}
if (-not $expectedLine) {
    throw "No SHA-256 for $filename in checksums.txt; refusing to install"
}
if (@($expectedLine).Count -ne 1) {
    throw "Ambiguous SHA-256 for $filename in checksums.txt; refusing to install"
}

$expected = ((@($expectedLine)[0] -split '\s+')[0]).ToLowerInvariant()
$actual = (Get-FileHash -Algorithm SHA256 -Path "$tmpDir\$filename").Hash.ToLowerInvariant()
if ($actual -ne $expected) {
    throw "Checksum mismatch for $filename (expected $expected, got $actual); refusing to install"
}

Expand-Archive -Path "$tmpDir\$filename" -DestinationPath $tmpDir -Force

New-Item -ItemType Directory -Path $installDir -Force | Out-Null
Move-Item -Path "$tmpDir\treehouse.exe" -Destination "$installDir\treehouse.exe" -Force

Remove-Item -Recurse -Force $tmpDir

# Add to PATH if not already there
$userPath = [Environment]::GetEnvironmentVariable("Path", "User")
if ($userPath -notlike "*$installDir*") {
    [Environment]::SetEnvironmentVariable("Path", "$userPath;$installDir", "User")
    Write-Host "Added $installDir to user PATH. Restart your terminal for it to take effect."
}

Write-Host "treehouse $version installed to $installDir\treehouse.exe"
