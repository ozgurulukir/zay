# Zay Agent Installer (Windows PowerShell)
# Usage:
#   irm https://raw.githubusercontent.com/ozgurulukir/zay/main/install.ps1 | iex
#   or:
#   curl.exe -fsSL https://raw.githubusercontent.com/ozgurulukir/zay/main/install.ps1 | iex

$ErrorActionPreference = 'Stop'

$Repo = "ozgurulukir/zay"
$InstallDir = if ($env:ZAY_INSTALL_DIR) { $env:ZAY_INSTALL_DIR } else { "$env:LOCALAPPDATA\Programs\zay" }
$BinName = "zay.exe"
$Artifact = "zay-windows-x86_64.exe"

Write-Host "==> Installing Zay Agent for Windows..." -ForegroundColor Cyan

# Check 64-bit architecture
if (-not [Environment]::Is64BitOperatingSystem) {
    Write-Error "Zay Agent currently supports 64-bit (x86_64) Windows only."
    exit 1
}

# Determine download version
if ($env:ZAY_VERSION) {
    $BaseUrl = "https://github.com/$Repo/releases/download/$env:ZAY_VERSION"
    Write-Host "Targeting version: $env:ZAY_VERSION"
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
    # Wrap ONLY the sidecar download in try/catch: a failed fetch (transient
    # network error) degrades to a warning. Everything below the catch runs
    # unguarded, because under $ErrorActionPreference = 'Stop' Write-Error is
    # a terminating error and the previously adjacent catch swallowed it as
    # "Checksum verification skipped" — a mismatched binary was then installed
    # by the Copy-Item below (#451). A mismatch or unparseable sidecar must
    # abort the install instead.
    $SidecarFetched = $true
    try {
        Invoke-WebRequest -Uri $ChecksumUrl -OutFile $TempShaPath -UseBasicParsing
    } catch {
        $SidecarFetched = $false
        Write-Host "Warning: Checksum verification skipped ($($_.Exception.Message))" -ForegroundColor Yellow
    }
    if ($SidecarFetched) {
        # Get-Content returns $null for a zero-byte sidecar, which made the
        # .Split below throw into the same skip path; guard it so an empty
        # sidecar fails closed too.
        $SidecarContent = Get-Content $TempShaPath
        if (-not $SidecarContent) {
            Write-Error "Checksum file is empty; refusing to install an unverified binary."
            exit 1
        }
        $ExpectedHash = $SidecarContent.Split(" ")[0].Trim()
        $ActualHash = (Get-FileHash -Path $TempArtifactPath -Algorithm SHA256).Hash.ToLower()

        if ((-not $ExpectedHash) -or ($ExpectedHash.ToLower() -ne $ActualHash)) {
            Write-Error "Checksum mismatch! Expected: $ExpectedHash, Actual: $ActualHash"
            exit 1
        }
        Write-Host "✓ Checksum verified." -ForegroundColor Green
    }

    $TargetBinary = Join-Path $InstallDir $BinName
    # Replace if exists
    Copy-Item -Path $TempArtifactPath -Destination $TargetBinary -Force
    Write-Host "==> Zay Agent installed successfully to $TargetBinary!" -ForegroundColor Green

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

    # Best-effort: install the offline registry seed (the vendored models.dev
    # snapshot) at <install-root>\share\zay\api.json — the runtime looks for
    # it one level above the exe directory and seeds its model cache from it
    # when the network is unavailable. Unlike the binary checksum above, this
    # fetch is graceful degradation: any failure warns and continues, and the
    # app fetches https://models.dev/api.json at runtime. An unverified seed
    # is never installed.
    $ApiTargetDir = Join-Path (Split-Path $InstallDir -Parent) "share\zay"
    $TempApiPath = Join-Path $TempDir "api.json"
    $TempApiShaPath = Join-Path $TempDir "api.json.sha256"
    try {
        Invoke-WebRequest -Uri "$BaseUrl/api.json" -OutFile $TempApiPath -UseBasicParsing -TimeoutSec 300
    } catch {
        Write-Host "Warning: api.json (offline registry seed) not downloaded ($($_.Exception.Message))" -ForegroundColor Yellow
    }
    if (Test-Path $TempApiPath) {
        $SeedVerified = $false
        try {
            Invoke-WebRequest -Uri "$BaseUrl/api.json.sha256" -OutFile $TempApiShaPath -UseBasicParsing -TimeoutSec 300
            $SeedExpected = (Get-Content $TempApiShaPath).Split(" ")[0].Trim()
            $SeedActual = (Get-FileHash -Path $TempApiPath -Algorithm SHA256).Hash.ToLower()
            if ($SeedExpected -and ($SeedExpected.ToLower() -eq $SeedActual)) {
                $SeedVerified = $true
            } else {
                Write-Host "Warning: api.json checksum mismatch; skipping the offline registry seed." -ForegroundColor Yellow
            }
        } catch {
            Write-Host "Warning: api.json checksum verification failed; skipping the offline registry seed." -ForegroundColor Yellow
        }
        if ($SeedVerified) {
            New-Item -ItemType Directory -Path $ApiTargetDir -Force | Out-Null
            Copy-Item -Path $TempApiPath -Destination (Join-Path $ApiTargetDir "api.json") -Force
            Write-Host "==> Installed offline registry seed to $(Join-Path $ApiTargetDir 'api.json')" -ForegroundColor Green
        }
    }

    Write-Host ""
    Write-Host "Zay Agent is ready to use!" -ForegroundColor Cyan
    Write-Host "Run 'zay' to get started." -ForegroundColor White
} finally {
    if (Test-Path $TempDir) {
        Remove-Item -Path $TempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
