[CmdletBinding()]
param(
    [Parameter()]
    [string]$VaxisDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$patchRoot = Join-Path $repoRoot "tools/vendor-patches"

function Get-VaxisCandidates {
    $vendorRoot = Join-Path $repoRoot "zig-pkg"
    if (-not (Test-Path -LiteralPath $vendorRoot -PathType Container)) {
        return @()
    }

    $candidates = @()
    foreach ($directory in Get-ChildItem -LiteralPath $vendorRoot -Directory -Filter "vaxis-*") {
        $appFile = Join-Path $directory.FullName "src/vxfw/App.zig"
        $loopFile = Join-Path $directory.FullName "src/Loop.zig"
        if (-not (Test-Path -LiteralPath $appFile -PathType Leaf)) {
            continue
        }
        if (-not (Test-Path -LiteralPath $loopFile -PathType Leaf)) {
            continue
        }
        $candidates += $directory.FullName
    }
    return $candidates
}

function Resolve-VaxisDirectory {
    param([string]$RequestedPath)

    if ($RequestedPath) {
        $resolved = Resolve-Path -LiteralPath $RequestedPath
        return $resolved.Path
    }

    $candidates = @(Get-VaxisCandidates)
    if ($candidates.Count -eq 0) {
        throw "No fetched vaxis directory was found under '$repoRoot/zig-pkg'. Run 'zig build --fetch' first, then pass -VaxisDir with the path printed by the build."
    }
    if ($candidates.Count -gt 1) {
        $paths = $candidates -join [Environment]::NewLine
        throw "More than one vaxis directory was found. Re-run with -VaxisDir and choose the dependency path used by the build:`n$paths"
    }
    return $candidates[0]
}

function Get-MarkerCount {
    param([string]$Path)

    $contents = Get-Content -LiteralPath $Path -Raw
    return ([regex]::Matches($contents, "ZAY-LOCAL-PATCH")).Count
}

function Apply-Patch {
    param(
        [string]$PatchPath,
        [string]$TargetDirectory,
        [string]$PatchExecutable
    )

    Write-Host "Applying $([System.IO.Path]::GetFileName($PatchPath)) ..."
    Get-Content -LiteralPath $PatchPath -Raw | & $PatchExecutable --forward --batch -p1 -d $TargetDirectory
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        throw "Patch failed with exit code ${exitCode}: $PatchPath"
    }
}

$targetDirectory = Resolve-VaxisDirectory -RequestedPath $VaxisDir
$appFile = Join-Path $targetDirectory "src/vxfw/App.zig"
$loopFile = Join-Path $targetDirectory "src/Loop.zig"
$patchExecutable = $null
if (-not (Test-Path -LiteralPath $appFile -PathType Leaf)) {
    throw "The selected vaxis directory is missing '$appFile'."
}
if (-not (Test-Path -LiteralPath $loopFile -PathType Leaf)) {
    throw "The selected vaxis directory is missing '$loopFile'."
}

$focusMarkerCount = Get-MarkerCount -Path $appFile
$loopMarkerCount = Get-MarkerCount -Path $loopFile
if ($focusMarkerCount -ge 2) {
    Write-Host "FocusHandler patch is already present ($focusMarkerCount markers)."
} else {
    $patchCommand = Get-Command patch.exe -ErrorAction SilentlyContinue
    if (-not $patchCommand) {
        throw "patch.exe was not found. Install Git for Windows or add its usr/bin directory to PATH, then re-run this script."
    }
    $patchExecutable = $patchCommand.Source
    Apply-Patch -PatchPath (Join-Path $patchRoot "vaxis-focus-handler.patch") -TargetDirectory $targetDirectory -PatchExecutable $patchExecutable
}

$loopMarkerCount = Get-MarkerCount -Path $loopFile
if ($loopMarkerCount -ge 6) {
    Write-Host "Loop input-thread patch is already present ($loopMarkerCount markers)."
} else {
    if (-not $patchExecutable) {
        $patchCommand = Get-Command patch.exe -ErrorAction SilentlyContinue
        if ($patchCommand) {
            $patchExecutable = $patchCommand.Source
        }
    }
    if (-not $patchExecutable) {
        throw "patch.exe was not found. Install Git for Windows or add its usr/bin directory to PATH, then re-run this script."
    }
    Apply-Patch -PatchPath (Join-Path $patchRoot "vaxis-input-thread-retry.patch") -TargetDirectory $targetDirectory -PatchExecutable $patchExecutable
}

$focusMarkerCount = Get-MarkerCount -Path $appFile
$loopMarkerCount = Get-MarkerCount -Path $loopFile
if ($focusMarkerCount -lt 2) {
    throw "FocusHandler patch verification failed: found $focusMarkerCount of 2 markers."
}
if ($loopMarkerCount -lt 6) {
    throw "Loop input-thread patch verification failed: found $loopMarkerCount of 6 markers."
}

Write-Host "vaxis patches are ready in $targetDirectory"
