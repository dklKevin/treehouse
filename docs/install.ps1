$ErrorActionPreference = "Stop"

# Pin a published release. Do not follow /releases/latest — that URL can
# move to an unverified asset. Fail closed unless checksums.txt matches.
$repo = "kunchenguid/treehouse"
$version = "v2.1.1"
$releaseBase = if ($env:TREEHOUSE_RELEASE_BASE) { $env:TREEHOUSE_RELEASE_BASE } else { "https://github.com/$repo/releases/download/$version" }

$installDir = if ($env:TREEHOUSE_INSTALL_DIR) { $env:TREEHOUSE_INSTALL_DIR } else { Join-Path $env:LOCALAPPDATA "treehouse" }

$arch = if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { "arm64" } else { "amd64" }

$versionNum = $version.TrimStart("v")
$filename = "treehouse-v$versionNum-windows-$arch.zip"
$url = "$releaseBase/$filename"
$checksumsUrl = "$releaseBase/checksums.txt"

$tmpDir = New-TemporaryFile | ForEach-Object { Remove-Item $_; New-Item -ItemType Directory -Path $_ }

Write-Host "Downloading treehouse $version for windows/$arch..."
try {
    Invoke-WebRequest -Uri $url -OutFile (Join-Path $tmpDir $filename)
} catch {
    throw "Failed to download $url"
}

Write-Host "Verifying against checksums.txt..."
$checksumsPath = Join-Path $tmpDir "checksums.txt"
try {
    Invoke-WebRequest -Uri $checksumsUrl -OutFile $checksumsPath
} catch {
    throw "Failed to download checksums.txt from $checksumsUrl"
}

$expected = $null
foreach ($line in Get-Content -Path $checksumsPath) {
    $fields = @($line.Trim() -split '\s+', 2)
    if ($fields.Count -eq 2 -and $fields[1] -eq $filename) {
        $expected = $fields[0]
        break
    }
}
if (-not $expected) {
    throw "checksums.txt has no SHA256 entry for $filename"
}
if ($expected -notmatch '^[0-9a-fA-F]{64}$') {
    throw "checksums.txt has an invalid SHA256 for $filename"
}

$actual = (Get-FileHash -Algorithm SHA256 -Path (Join-Path $tmpDir $filename)).Hash
if ($actual.ToLowerInvariant() -ne $expected.ToLowerInvariant()) {
    throw "Checksum mismatch for $filename (expected $expected, got $actual)"
}

Expand-Archive -Path (Join-Path $tmpDir $filename) -DestinationPath $tmpDir -Force

New-Item -ItemType Directory -Path $installDir -Force | Out-Null
Move-Item -Path (Join-Path $tmpDir "treehouse.exe") -Destination (Join-Path $installDir "treehouse.exe") -Force

Remove-Item -Recurse -Force $tmpDir

# Add to PATH if not already there (skip when the caller set a custom dir).
if (-not $env:TREEHOUSE_INSTALL_DIR) {
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    if ($userPath -notlike "*$installDir*") {
        [Environment]::SetEnvironmentVariable("Path", "$userPath;$installDir", "User")
        Write-Host "Added $installDir to user PATH. Restart your terminal for it to take effect."
    }
}

Write-Host "treehouse $version installed to $(Join-Path $installDir 'treehouse.exe')"
