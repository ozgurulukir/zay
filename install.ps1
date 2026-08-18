# Nova Agent Installer (Windows PowerShell)
# Usage:
#   irm https://raw.githubusercontent.com/ozgurulukir/nova-agent/main/install.ps1 | iex
#   or:
#   curl.exe -fsSL https://raw.githubusercontent.com/ozgurulukir/nova-agent/main/install.ps1 | iex

$ErrorActionPreference = 'Stop'

$Repo = "ozgurulukir/nova-agent"
$InstallDir = if ($env:NOVA_INSTALL_DIR) { $env:NOVA_INSTALL_DIR } else { "$env:LOCALAPPDATA\Programs\nova" }
$BinName = "nova.exe"
$Artifact = "nova-windows-x86_64.exe"

Write-Host "==> Installing Nova Agent for Windows..." -ForegroundColor Cyan

# Check 64-bit architecture
if (-not [Environment]::Is64BitOperatingSystem) {
    Write-Error "Nova Agent currently supports 64-bit (x86_64) Windows only."
    exit 1
}

# Determine download version
if ($env:NOVA_VERSION) {
    $BaseUrl = "https://github.com/$Repo/releases/download/$env:NOVA_VERSION"
    Write-Host "Targeting version: $env:NOVA_VERSION"
} else {
    $BaseUrl = "https://github.com/$Repo/releases/latest/download"
    Write-Host "Targeting version: latest"
}

$DownloadUrl = "$BaseUrl/$Artifact"
$ChecksumUrl = "$BaseUrl/$Artifact.sha256"

# Create target directory
if (-not (Test-Path $InstallDir)) {
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
}

$TempDir = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), [System.Guid]::NewGuid().ToString())
New-Item -ItemType Directory -Path $TempDir -Force | Out-Null

try {
    $TempArtifactPath = Join-Path $TempDir $Artifact
    $TempShaPath = Join-Path $TempDir "$Artifact.sha256"

    Write-Host "==> Downloading $Artifact..." -ForegroundColor Cyan
    Invoke-WebRequest -Uri $DownloadUrl -OutFile $TempArtifactPath -UseBasicParsing

    Write-Host "==> Verifying SHA256 checksum..." -ForegroundColor Cyan
    try {
        Invoke-WebRequest -Uri $ChecksumUrl -OutFile $TempShaPath -UseBasicParsing
        $ExpectedHash = (Get-Content $TempShaPath).Split(" ")[0].Trim()
        $ActualHash = (Get-FileHash -Path $TempArtifactPath -Algorithm SHA256).Hash.ToLower()

        if ($ExpectedHash.ToLower() -ne $ActualHash) {
            Write-Error "Checksum mismatch! Expected: $ExpectedHash, Actual: $ActualHash"
            exit 1
        }
        Write-Host "✓ Checksum verified." -ForegroundColor Green
    } catch {
        Write-Host "Warning: Checksum verification skipped ($($_.Exception.Message))" -ForegroundColor Yellow
    }

    $TargetBinary = Join-Path $InstallDir $BinName
    # Replace if exists
    Copy-Item -Path $TempArtifactPath -Destination $TargetBinary -Force
    Write-Host "==> Nova Agent installed successfully to $TargetBinary!" -ForegroundColor Green

    # Ensure target directory is in user PATH
    $UserPath = [Environment]::GetEnvironmentVariable("Path", "User")
    $PathEntries = if ($UserPath) { $UserPath.Split(';') } else { @() }
    
    if ($PathEntries -notcontains $InstallDir) {
        $NewPath = if ($UserPath) { "$UserPath;$InstallDir" } else { $InstallDir }
        [Environment]::SetEnvironmentVariable("Path", $NewPath, "User")
        Write-Host "==> Added $InstallDir to User PATH." -ForegroundColor Green
    }

    # Add to current session PATH
    if ($env:PATH.Split(';') -notcontains $InstallDir) {
        $env:PATH = "$InstallDir;$env:PATH"
    }

    Write-Host ""
    Write-Host "Nova Agent is ready to use!" -ForegroundColor Cyan
    Write-Host "Run 'nova --help' to get started." -ForegroundColor White
} finally {
    if (Test-Path $TempDir) {
        Remove-Item -Path $TempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
